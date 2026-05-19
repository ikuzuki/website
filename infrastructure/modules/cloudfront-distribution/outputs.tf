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
