# Bootstrap — creates the Terraform state backend (S3 + DynamoDB lock) and
# the GitHub Actions OIDC trust + CICD IAM role. Run once locally with
# local state, then the env roots use the S3 backend below.
#
# The OIDC provider is account-wide and already exists in this AWS account
# (created by the fpl-platform bootstrap). We data-source it rather than
# creating a duplicate — AWS only permits one provider per issuer URL.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project   = "issei-website"
      ManagedBy = "terraform"
      Owner     = "issei"
    }
  }
}

# --- Terraform state bucket ---
resource "aws_s3_bucket" "tf_state" {
  bucket = "issei-website-tf-state"
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket                  = aws_s3_bucket.tf_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- DynamoDB lock table ---
resource "aws_dynamodb_table" "tf_lock" {
  name         = "issei-website-tf-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

# --- GitHub Actions OIDC trust ---
# Provider already exists at the account level (shared with fpl-platform).
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:*"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# Scoped policy for the website deploy pipeline. Narrower than fpl's
# AdministratorAccess — the deploy role only needs to manage S3, CloudFront,
# IAM (for the resources it creates), and a few read-only APIs.
data "aws_iam_policy_document" "cicd" {
  statement {
    sid    = "S3SiteAndState"
    effect = "Allow"
    actions = [
      "s3:*",
    ]
    resources = [
      "arn:aws:s3:::issei-website-*",
      "arn:aws:s3:::issei-website-*/*",
    ]
  }

  statement {
    sid    = "DynamoDBLock"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
      "dynamodb:DescribeTable",
    ]
    resources = [aws_dynamodb_table.tf_lock.arn]
  }

  statement {
    sid    = "CloudFrontFull"
    effect = "Allow"
    actions = [
      "cloudfront:*",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "IamReadAndPassForOAC"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:ListRoles",
      "iam:PassRole",
    ]
    resources = ["*"]
  }

  # Terraform plan needs to read tags, account info, regions.
  statement {
    sid    = "ReadOnlyDiscovery"
    effect = "Allow"
    actions = [
      "sts:GetCallerIdentity",
      "tag:GetResources",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "cicd" {
  name               = "Issei-Website-CICD-Role"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume.json
}

resource "aws_iam_role_policy" "cicd" {
  name   = "issei-website-cicd-policy"
  role   = aws_iam_role.cicd.id
  policy = data.aws_iam_policy_document.cicd.json
}

output "cicd_role_arn" {
  description = "ARN to set as the AWS_CICD_ROLE_ARN secret on the GitHub repo."
  value       = aws_iam_role.cicd.arn
}

output "state_bucket" {
  value = aws_s3_bucket.tf_state.id
}

output "lock_table" {
  value = aws_dynamodb_table.tf_lock.id
}
