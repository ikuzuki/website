# website

Personal site for Issei Kuzuki. Astro static site, hosted on S3 +
CloudFront, deployed via GitHub Actions with OIDC into AWS.

## Stack

- **Astro 5** - static site generator. Content Collections for the blog.
- **MDX** - blog posts in markdown with optional component embedding.
- **AWS S3 + CloudFront** - private bucket, OAC-signed, default
  CloudFront cert until a custom domain is wired up.
- **Terraform** - all infra in `infrastructure/`, two-stage (bootstrap
  for state and OIDC, then env for the actual site).
- **GitHub Actions** - OIDC into AWS, runs `terraform apply` on infra
  changes, builds and uploads the site on content changes, invalidates
  CloudFront on every deploy.

## Local dev

```
npm install
npm run dev
```

The dev server runs at `http://localhost:4321`.

## Build

```
npm run build
```

Output lands in `dist/`.

## Infrastructure

Two Terraform roots:

- `infrastructure/bootstrap/` - state bucket, lock table, OIDC trust to
  the GitHub Actions role. Run once, by hand, with local state.
- `infrastructure/environments/dev/` - S3 site bucket, CloudFront
  distribution, bucket policy. Remote state in S3. Subsequent applies
  run via GitHub Actions.

### First-time provisioning

```bash
# Bootstrap (creates state bucket, OIDC trust, CICD role)
cd infrastructure/bootstrap
terraform init
terraform apply

# Dev environment (creates S3 site bucket + CloudFront)
cd ../environments/dev
terraform init
terraform apply

terraform output cloudfront_domain          # the live URL
terraform output cloudfront_distribution_id # set as repo secret
```

### Repo secrets

`AWS_CICD_ROLE_ARN` and `CLOUDFRONT_DISTRIBUTION_ID` are required by
the deploy workflow. Set them via `gh secret set` after the first
apply.

## Adding a blog post

Drop a `.md` or `.mdx` file into `src/content/blog/` with the required
frontmatter:

```yaml
---
title: Post title
description: One-line description, used for SEO and the post list.
pubDate: 2026-06-01
draft: false
tags: [aws, llm]
---
```

`draft: true` posts are excluded from the build.

## Domain

Live at `https://isseikuzuki.co.uk/`. The CloudFront distribution serves
the apex and `www.` via an ACM cert in `us-east-1` (CloudFront only
reads certs from us-east-1), with Route 53 alias records pointing both
hostnames at the distribution.

The original CloudFront default domain (`*.cloudfront.net`) still
resolves; the custom domain is layered on via the `aliases` argument
in `infrastructure/modules/cloudfront-distribution` plus DNS-validated
cert.

## Repo secrets

`AWS_CICD_ROLE_ARN` and `CLOUDFRONT_DISTRIBUTION_ID` are set on the
repo. Re-run `terraform apply` if either rotates.

## Current state

- Bootstrap applied: state bucket `issei-website-tf-state`, lock table
  `issei-website-tf-lock`, role `Issei-Website-CICD-Role`.
- Dev env applied: bucket `issei-website-dev`, CloudFront distribution
  fronting the apex and `www.` of `isseikuzuki.co.uk`.
- Site is live; deploys land on every push to `main`.
