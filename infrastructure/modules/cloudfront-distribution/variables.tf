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
