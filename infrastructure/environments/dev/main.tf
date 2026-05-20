terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "issei-website-tf-state"
    key            = "dev/terraform.tfstate"
    region         = "eu-west-2"
    dynamodb_table = "issei-website-tf-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "issei-website"
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = "issei"
    }
  }
}

locals {
  name = "issei-website-${var.environment}"
}

module "site_bucket" {
  source      = "../../modules/s3-static-site"
  bucket_name = local.name
}

module "cdn" {
  source                           = "../../modules/cloudfront-distribution"
  name                             = local.name
  site_bucket_regional_domain_name = module.site_bucket.bucket_regional_domain_name
  acm_certificate_arn              = aws_acm_certificate_validation.site.certificate_arn
  aliases                          = [var.domain_name, "www.${var.domain_name}"]
}

# Bucket policy lives here so it can reference the distribution ARN without
# creating a module-to-module circular dependency.
data "aws_iam_policy_document" "site" {
  statement {
    sid    = "AllowCloudFrontOAC"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    actions   = ["s3:GetObject"]
    resources = ["${module.site_bucket.bucket_arn}/*"]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [module.cdn.distribution_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket = module.site_bucket.bucket_id
  policy = data.aws_iam_policy_document.site.json
}
