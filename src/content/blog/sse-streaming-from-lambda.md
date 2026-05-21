---
title: An evening with OAC, POST, and SigV4
description: I tried to put a CloudFront-fronted Lambda Function URL with OAC and AWS_IAM in front of an SSE-streaming agent. 100% of POSTs returned 403. Here's the evening.
pubDate: 2026-05-15
draft: false
tags: [aws, lambda, cloudfront, sse, streaming]
---

The agent sits on a Lambda Function URL. It streams response tokens back to the browser over Server-Sent Events. I'd put it behind CloudFront for the usual reasons: the dashboard was already on CloudFront, the Function URL shouldn't be reachable directly, and I wanted edge rate-limiting cheaply. The textbook pattern is CloudFront Origin Access Control with `AWS_IAM` on the Function URL. CloudFront signs each origin request, the Function URL validates the signature, anything that arrives unsigned gets a 403. The Terraform module took twenty minutes. The DNS came up. I opened the dashboard, hit "ask the agent something", and got a 403.

GETs to `/health` worked. POSTs to `/chat` did not. Identical IAM, identical OAC, identical everything except the verb.

I spent the next stretch of hours flipping between configurations. Added the missing `lambda:InvokeFunction` permission alongside `lambda:InvokeFunctionUrl` after seeing the rumour go round that the October 2025 IAM change required both<sup>1</sup>. Reverted `auth_type` to `NONE` to confirm the dashboard could even reach the Lambda, then back to `AWS_IAM` with OAC restored. Tried a fresh distribution. Tried it without the custom origin policy. Bumped Lambda memory in case it was a cold-start timing thing. Each fix made plausible sense in isolation and none of them touched the actual problem. Same result every time: GET works, POST doesn't.

The hint that broke the case was that the 403 looked like a real signature mismatch in the CloudWatch logs, not a permissions error. AWS isn't generous with error messages here; you get "InvalidSignatureException" with a hash that doesn't match what your local SigV4 computation produces. I started reading the SigV4 spec properly for the first time. I'd used it through SDKs for years and never had to think about what the canonical request actually contained. The canonical request includes the hex-encoded SHA256 of the body. For a GET that's the hash of an empty string, a constant that browsers and CloudFront and AWS all agree on. For a POST, the hash depends on the body. CloudFront has to compute it and put it in the canonical request before signing.

Here is where it falls apart. CloudFront with OAC computes the body hash if (and only if) the request body is fully buffered at the edge. For non-streaming POSTs that's fine; CloudFront buffers, hashes, signs, forwards. For SSE-shaped requests, where the body is a stream rather than a buffered chunk, CloudFront can't compute the hash in time, the body-hash header doesn't make it into the signed canonical request, and the Function URL rejects what arrives. The constraint is documented, in a footnote, on an AWS page I didn't find until I'd already fixed the issue another way.

Every AWS example for OAC plus Function URL uses GET. Every blog post showing the pattern uses GET. The pattern is documented for GETs and silently broken for streaming POSTs. I'd been pattern-matching off examples that never exercised my actual case.

The fix turned out to be embarrassingly simple. Set the Function URL to `auth_type = NONE`, which makes the URL technically public, then inject a shared-secret header on every CloudFront origin request. The Lambda's FastAPI middleware rejects any request whose `X-CloudFront-Secret` header doesn't match the expected value, which is read from SSM SecureString at cold start and cached for the warm lifetime of the container. The Function URL is "public" in name and unreachable in practice; anyone hitting the raw URL gets a 403 from the middleware because they don't have the header. CloudFront is the only thing that knows the header, so CloudFront is the only thing that can reach the Lambda.

<figure>
  <img src="/diagrams/cloudfront-shared-secret.svg" alt="Two paths converge on the FastAPI middleware. Browser through CloudFront injects the X-CloudFront-Secret header and reaches the Scout Agent; anyone hitting the raw Function URL directly has no header and gets rejected. A second DynamoDB budget cap layer rejects with 429 if the per-request budget is exceeded." />
  <figcaption>Two layers of defence in depth. Shared-secret header at the edge, DynamoDB budget and rate cap at the runtime.</figcaption>
</figure>

The Terraform shape is roughly:

```hcl
resource "aws_cloudfront_distribution" "main" {
  # ...
  origin {
    domain_name = aws_lambda_function_url.agent.url_id
    origin_id   = "agent"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    custom_header {
      name  = "X-CloudFront-Secret"
      value = aws_ssm_parameter.cf_secret.value
    }
  }
}
```

And in the Lambda, a single middleware:

```python
@app.middleware("http")
async def require_shared_secret(request, call_next):
    expected = get_cached_secret()
    if request.headers.get("X-CloudFront-Secret") != expected:
        return Response(status_code=403)
    return await call_next(request)
```

That's the entirety of the fix. It's less principled than OAC plus AWS_IAM. There's a shared secret in the world that, if leaked, lets anyone bypass CloudFront. The mitigations are standard: store it in SSM SecureString, rotate it occasionally, never log it, never commit it. None of those are exotic and the cost is small.

A few cache-behaviour details that I'd be more annoyed at myself for missing if I'd missed them: forward `Cache-Control: no-cache` and don't cache responses on the SSE path, because CloudFront cheerfully tries to cache the stream and either fails or, worse, serves cached partial streams to other users. The AWS-managed `CachingDisabled` policy is the right pick. Use `AllViewerExceptHostHeader` for the origin request policy, because the Function URL rejects requests whose `Host` doesn't match its own domain, so forwarding the dashboard's host header would 403 every request before it even reached the middleware. Allowed methods on the behaviour need to include POST explicitly, because the default doesn't, and a missing POST entry silently 405s the agent. None of these were the bug. All of them were potholes I drove around in the dark.

The story ends here. The agent streams, the dashboard works, the ADR went into the FPL repo as [ADR-010](https://github.com/ikuzuki/fpl-platform/blob/main/docs/adrs/adr-010-cloudfront-shared-secret.md). The thing I want future-me to remember, on the assumption that future-me is in a different AWS rabbit hole at the time, is to look for the edge of the example rather than the centre.

---

<sup>1</sup> The October 2025 change is real and was a separate landmine on the same evening; I just lucked into finding both at once. The resource policy now needs `lambda:InvokeFunctionUrl` and `lambda:InvokeFunction` for CloudFront via OAC to invoke. AWS announced it on a service-update post that didn't get picked up by the major guide sites for weeks. If you're seeing 403s on a freshly-deployed CloudFront → Function URL setup, check the resource policy actions list first.
