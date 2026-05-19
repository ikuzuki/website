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

Currently published at the CloudFront default domain
`https://de5chlefe7o13.cloudfront.net/`. Custom domain wiring (ACM cert
in `us-east-1`, Route 53 alias, CloudFront alternate domain name) lands
in a follow-up once the domain is registered.

## Activating the deploy workflow

The first push happened with a token that lacked `workflow` scope, so
the deploy file is parked at `.github/workflows.pending-deploy.yml`.
To activate:

```bash
gh auth refresh -s workflow
git mv .github/workflows.pending-deploy.yml .github/workflows/deploy.yml
git commit -m "ci: enable deploy workflow"
git push
```

Repo secrets `AWS_CICD_ROLE_ARN` and `CLOUDFRONT_DISTRIBUTION_ID` are
already set.

## Current state

- Bootstrap applied: state bucket `issei-website-tf-state`, lock table
  `issei-website-tf-lock`, role `Issei-Website-CICD-Role`.
- Dev env applied: bucket `issei-website-dev`, distribution
  `E3MCUNVBQ8D4EU`, domain `de5chlefe7o13.cloudfront.net`.
- Site is live and serving the placeholder content.
