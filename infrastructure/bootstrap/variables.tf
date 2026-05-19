variable "region" {
  type    = string
  default = "eu-west-2"
}

variable "aws_profile" {
  description = "Local AWS profile to use for the one-off bootstrap apply."
  type        = string
  default     = "fpl-dev"
}

variable "github_repo" {
  description = "GitHub repository in 'owner/repo' form. Used to scope the OIDC trust."
  type        = string
  default     = "ikuzuki/website"
}
