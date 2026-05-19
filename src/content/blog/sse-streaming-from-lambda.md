---
title: SSE streaming from a Lambda Function URL, the OAC landmine, and the fix
description: I tried to put a CloudFront-fronted Lambda Function URL with OAC + AWS_IAM in front of an SSE-streaming agent. 100% of POSTs returned 403. Here's why, and what to do instead.
pubDate: 2026-05-19
draft: true
tags: [aws, lambda, cloudfront, sse, streaming]
---

I built an agent on a Lambda Function URL. It streams response tokens back to the browser over Server-Sent Events. I put it behind CloudFront because (a) the dashboard's already on CloudFront, (b) the Function URL shouldn't be reachable directly, (c) I wanted edge rate-limiting.

The textbook pattern is CloudFront Origin Access Control with `AWS_IAM` auth on the Function URL. CloudFront signs each origin request with SigV4; the Function URL validates the signature; anything not signed by CloudFront gets a 403.

100% of POST requests returned 403.

GETs worked. POSTs didn't. Identical IAM, identical OAC, identical everything except the verb. I spent an evening on this and an ADR came out the other end. This is the writeup.

## What SigV4 needs and why POST breaks it

SigV4 — the AWS request signing scheme — needs the SHA256 of the request body in the canonical request that gets signed. For GETs this is the hash of an empty string, which is a constant: `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`. No body, no problem; the hash is deterministic and the signature can be computed up front.

For POSTs, the hash depends on the body. CloudFront has to compute it and put it in the canonical request before signing.

Here's where it falls apart: CloudFront with OAC computes the body hash *only* if the request body is fully buffered at the edge. For non-streaming POSTs that works fine; CloudFront buffers the body, hashes it, signs the request, forwards it. For SSE-shaped requests — long-lived connections, streaming response bodies, sometimes streaming request bodies too — CloudFront can't buffer the body the same way, and the body-hash header isn't present in the signed canonical request. The Function URL receives an OAC-signed request with no payload hash header, and SigV4 validation rejects it with a 403.

The AWS docs for OAC + Function URL list this constraint, in a footnote, on a page that nobody finds until they're already debugging it. Every example in the main flow uses GET, where the issue doesn't surface.

Net effect: OAC + AWS_IAM is the smart default, it's everywhere in AWS examples, and it silently breaks the moment your origin is a streaming POST endpoint.

## The secondary landmine

While debugging this I also tripped on a second issue: as of October 2025, AWS requires *both* `lambda:InvokeFunctionUrl` and `lambda:InvokeFunction` on the resource policy when CloudFront invokes via OAC. Older guides only grant `InvokeFunctionUrl`; older Terraform modules only grant `InvokeFunctionUrl`. Recently-created Function URLs using those modules 403 with no helpful error.

I don't have a great explanation for why this change was made or why it isn't louder. It's a known thing that bit a lot of people in late 2025 and the deeper guides have been updated, but the surface-level ones haven't. If you're seeing 403s on a new CloudFront → Function URL setup, check the resource policy actions list before anything else.

## What works instead

The fix is to drop OAC + AWS_IAM and use a shared secret instead.

1. Set the Function URL to `auth_type = NONE`. The URL is now public — anyone who knows it can call it directly.
2. On the CloudFront distribution, create an origin-request policy that injects a custom header on every request to the origin, with a value held in SSM SecureString and resolved at Terraform apply time. Call it something obvious, like `X-CloudFront-Secret`.
3. In the Lambda's FastAPI app, add a middleware that rejects any request whose `X-CloudFront-Secret` header doesn't match the expected value (read from SSM at cold start, cached for the warm lifetime of the container).

The Function URL is now public *in name*, but unreachable in practice — anyone who tries the raw URL gets a 403 because they don't have the header. CloudFront is the only thing that knows the header, so CloudFront is the only thing that can reach the Lambda.

The Terraform shape:

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
  # ...
}
```

And in the Lambda:

```python
@app.middleware("http")
async def require_shared_secret(request, call_next):
    expected = get_cached_secret()
    if request.headers.get("X-CloudFront-Secret") != expected:
        return Response(status_code=403)
    return await call_next(request)
```

That's the entirety of the fix. It's less principled than OAC + AWS_IAM — there's a shared secret in the world that, if leaked, lets anyone bypass CloudFront. The mitigations are standard: store it in SSM SecureString, rotate it occasionally, never log it. None of those are exotic.

## The CloudFront cache behaviour, briefly

A few things that took an extra hour to get right around the cache behaviour for the SSE path.

The behaviour has to forward `Cache-Control: no-cache` to the origin and not cache responses. Otherwise CloudFront tries to cache the stream, which makes the whole thing either fail or — worse — serve cached partial streams to other users. AWS-managed `CachingDisabled` policy is the right pick.

The behaviour also needs to forward all the headers the origin cares about, including `Authorization` and `Content-Type`. AWS-managed `AllViewerExceptHostHeader` does this — forwards everything except `Host`. That last exception is load-bearing: the Function URL rejects requests whose `Host` doesn't match its own domain, and if CloudFront forwards the dashboard's host header, the Lambda 403s.

Allowed methods on the behaviour: GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE. The default doesn't include POST, which silently 405s the agent.

OPTIONS preflight: the FastAPI app needs explicit CORS middleware for the dashboard's origin. CloudFront doesn't generate the CORS response; the origin does, and CloudFront passes it through.

## The URL-rewriting bit

One more thing that's specific to my setup but worth mentioning. The agent FastAPI app has routes like `/chat`, `/health`, `/team`. The CloudFront behaviour is at path pattern `/api/agent/*`. By default, a request for `https://dashboard.example/api/agent/chat` would reach the Lambda as `/api/agent/chat`, which doesn't match any route.

The fix is a CloudFront Function (not a Lambda@Edge — Functions are cheaper and faster for header/URI manipulation) on viewer-request that rewrites the URI:

```javascript
function handler(event) {
    var request = event.request;
    if (request.uri.startsWith('/api/agent')) {
        request.uri = request.uri.replace(/^\/api\/agent/, '');
        if (request.uri === '') request.uri = '/';
    }
    return request;
}
```

CloudFront Functions run at ~1ms per invocation, and they're free up to 10 million invocations per month. For URI rewrites this is the right tool.

## Generalising

The specific bug here — OAC + AWS_IAM silently breaks SSE POSTs — is unlikely to apply to most readers. The pattern around it is general: the smart default broke because my use case diverged from the example use case in a small but load-bearing way. Every AWS example for OAC + Function URL uses GET. The pattern is silent on POSTs. The pattern is silent on streaming. My use case was streaming POSTs. The platform fails silently rather than telling me.

This shape recurs. AWS examples use the simplest case that demonstrates the feature; production usage diverges; the divergence is small but matters; nothing flags it. The defending pattern is the same as for every other "the textbook is silent on my edge case" landmine: when something doesn't work and the docs say it should, look for the edge of the example, not the centre. The bug is almost always at the edge.

For the future-me searching this: if you see "OAC POST 403" or "CloudFront Function URL SigV4 streaming" or anything similar, drop OAC, set the Function URL to `auth_type = NONE`, inject a shared-secret header. It works. The principled solution doesn't, and won't until AWS ships the streaming-body hash variant they presumably know about.
