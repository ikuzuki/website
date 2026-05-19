output "site_bucket" {
  description = "Name of the S3 bucket the deploy uploads to."
  value       = module.site_bucket.bucket_id
}

output "cloudfront_domain" {
  description = "Live URL (CloudFront default domain) until a custom domain is wired."
  value       = module.cdn.domain_name
}

output "cloudfront_distribution_id" {
  description = "Distribution ID — set this as the CLOUDFRONT_DISTRIBUTION_ID repo secret."
  value       = module.cdn.distribution_id
}
