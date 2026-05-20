# Custom-domain wiring: ACM certificate (in us-east-1, mandatory for CloudFront)
# + DNS validation records + apex/www alias records pointing at the distribution.

# CloudFront only reads ACM certs from us-east-1. The rest of the stack lives
# in eu-west-2 (London). Aliased provider for the us-east-1 cert.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = "issei-website"
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = "issei"
    }
  }
}

# Hosted zone created automatically by Route 53 Domains when the domain was
# registered. Looked up by name rather than ID for portability.
data "aws_route53_zone" "primary" {
  name = var.domain_name
}

# Certificate covers apex + www. Subject alternative names (SAN) on a single
# cert is cheaper than two certs and behaves identically.
resource "aws_acm_certificate" "site" {
  provider = aws.us_east_1

  domain_name               = var.domain_name
  subject_alternative_names = ["www.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# DNS validation: ACM publishes a CNAME challenge for each domain on the cert,
# Terraform writes those CNAMEs into the hosted zone, ACM checks them, and the
# cert flips from PENDING_VALIDATION to ISSUED.
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.site.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.primary.zone_id
}

# Explicit "wait for validation" resource. Downstream resources (the CloudFront
# distribution's viewer_certificate block) depend on this rather than on the
# cert itself, ensuring CloudFront only sees the cert after it's been validated.
resource "aws_acm_certificate_validation" "site" {
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.site.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# A and AAAA alias records pointing apex + www at the CloudFront distribution.
# Alias records (not CNAMEs) so the apex can point at a CloudFront distribution
# without violating DNS rules. AWS-internal magic; only works for Route 53 +
# AWS targets.
resource "aws_route53_record" "apex_a" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = module.cdn.domain_name
    zone_id                = module.cdn.distribution_hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "apex_aaaa" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = var.domain_name
  type    = "AAAA"

  alias {
    name                   = module.cdn.domain_name
    zone_id                = module.cdn.distribution_hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "www_a" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = "www.${var.domain_name}"
  type    = "A"

  alias {
    name                   = module.cdn.domain_name
    zone_id                = module.cdn.distribution_hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "www_aaaa" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = "www.${var.domain_name}"
  type    = "AAAA"

  alias {
    name                   = module.cdn.domain_name
    zone_id                = module.cdn.distribution_hosted_zone_id
    evaluate_target_health = false
  }
}
