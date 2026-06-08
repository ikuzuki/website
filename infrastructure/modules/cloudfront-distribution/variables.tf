variable "name" {
  description = "Logical name (used in resource names and the distribution comment)."
  type        = string
}

variable "site_bucket_regional_domain_name" {
  description = "Regional domain name of the S3 site bucket (e.g. bucket.s3.eu-west-2.amazonaws.com)."
  type        = string
}

variable "price_class" {
  description = "CloudFront price class. PriceClass_100 covers US/Europe (cheapest)."
  type        = string
  default     = "PriceClass_100"
}

variable "acm_certificate_arn" {
  description = "ARN of an ACM certificate in us-east-1 to serve HTTPS for the custom domain. If null, CloudFront uses its default *.cloudfront.net certificate."
  type        = string
  default     = null
}

variable "aliases" {
  description = "List of custom domain names (CNAMEs) the distribution serves. Each must be covered by the ACM certificate."
  type        = list(string)
  default     = []
}

variable "log_bucket_domain" {
  description = "Bucket domain for CloudFront standard access logs (e.g. ikuzuki-analytics-logs.s3.eu-west-2.amazonaws.com). Null disables logging."
  type        = string
  default     = null
}

variable "log_prefix" {
  description = "Key prefix for delivered access logs within the log bucket (e.g. cloudfront/website/)."
  type        = string
  default     = ""
}
