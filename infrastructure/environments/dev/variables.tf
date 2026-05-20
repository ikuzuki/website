variable "region" {
  type    = string
  default = "eu-west-2"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "domain_name" {
  description = "Apex domain for the site. The Route 53 hosted zone (created automatically by Route 53 Domains on registration) must already exist."
  type        = string
  default     = "isseikuzuki.co.uk"
}
