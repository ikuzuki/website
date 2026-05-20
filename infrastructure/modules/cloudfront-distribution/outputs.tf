output "distribution_id" {
  value = aws_cloudfront_distribution.site.id
}

output "distribution_arn" {
  value = aws_cloudfront_distribution.site.arn
}

output "domain_name" {
  description = "Live URL — the *.cloudfront.net default domain."
  value       = aws_cloudfront_distribution.site.domain_name
}

output "distribution_hosted_zone_id" {
  description = "CloudFront's Route 53 hosted zone ID (constant Z2FDTNDATAQYW2). Used as the alias target zone for A/AAAA records pointing at the distribution."
  value       = aws_cloudfront_distribution.site.hosted_zone_id
}
