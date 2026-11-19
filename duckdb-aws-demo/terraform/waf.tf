# AWS WAF for the CloudFront distribution (scope CLOUDFRONT, us-east-1).
# Default action: block. Only clients in var.allowed_cidrs get through, and then they
# still have to sign in with Cognito.
#
# The AWS managed Core rule set and SQL injection rule set are deliberately not used:
# the DuckDB UI sends SQL in request bodies, which those rules would block.

locals {
  allowed_v4 = [for c in var.allowed_cidrs : c if can(cidrnetmask(c))]
  allowed_v6 = [for c in var.allowed_cidrs : c if !can(cidrnetmask(c))]
}

resource "aws_wafv2_ip_set" "allowed_v4" {
  provider           = aws.us_east_1
  name               = "${local.name}-allowed-v4"
  scope              = "CLOUDFRONT"
  ip_address_version = "IPV4"
  addresses          = local.allowed_v4
}

resource "aws_wafv2_ip_set" "allowed_v6" {
  provider           = aws.us_east_1
  name               = "${local.name}-allowed-v6"
  scope              = "CLOUDFRONT"
  ip_address_version = "IPV6"
  addresses          = local.allowed_v6
}

resource "aws_wafv2_web_acl" "ui" {
  provider = aws.us_east_1
  name     = "${local.name}-ui"
  scope    = "CLOUDFRONT"

  default_action {
    block {}
  }

  rule {
    name     = "rate-limit-per-ip"
    priority = 0
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-ip-reputation"
    priority = 1
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesAmazonIpReputationList"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-known-bad-inputs"
    priority = 2
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "allow-listed-clients"
    priority = 3
    action {
      allow {}
    }
    statement {
      or_statement {
        statement {
          ip_set_reference_statement {
            arn = aws_wafv2_ip_set.allowed_v4.arn
          }
        }
        statement {
          ip_set_reference_statement {
            arn = aws_wafv2_ip_set.allowed_v6.arn
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "allow-listed"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name}-ui"
    sampled_requests_enabled   = true
  }
}

# WAF logs every request (allowed and blocked); they double as the access log.
resource "aws_cloudwatch_log_group" "waf" {
  provider          = aws.us_east_1
  name              = "aws-waf-logs-${local.name}"
  retention_in_days = var.log_retention_days
}

resource "aws_wafv2_web_acl_logging_configuration" "ui" {
  provider                = aws.us_east_1
  resource_arn            = aws_wafv2_web_acl.ui.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]

  # Never log the Cognito token cookies.
  redacted_fields {
    single_header {
      name = "cookie"
    }
  }
  redacted_fields {
    single_header {
      name = "authorization"
    }
  }
}
