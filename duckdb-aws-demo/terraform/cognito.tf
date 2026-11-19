# Cognito user pool: one admin user, no self sign-up, optional TOTP MFA.
# Lambda@Edge (edge.tf) redirects every unauthenticated viewer to the managed login page
# and verifies the ID token cookie on each request.

resource "aws_cognito_user_pool" "main" {
  name                     = "${local.name}-users"
  user_pool_tier           = "ESSENTIALS"
  deletion_protection      = "INACTIVE"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  mfa_configuration        = var.mfa_configuration

  admin_create_user_config {
    allow_admin_create_user_only = true
    invite_message_template {
      email_subject = "DuckDB on S3 Tables demo: your temporary password"
      email_message = "Your username is {username} and your temporary password is {####}. Sign in through the demo URL and set a new password."
      sms_message   = "Username {username}, temporary password {####}"
    }
  }

  password_policy {
    minimum_length                   = 14
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 3
  }

  software_token_mfa_configuration {
    enabled = true
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  username_configuration {
    case_sensitive = false
  }
}

resource "aws_cognito_user_pool_domain" "main" {
  domain                = "${local.name}-${local.suffix}"
  user_pool_id          = aws_cognito_user_pool.main.id
  managed_login_version = 2
}

resource "aws_cognito_user_pool_client" "ui" {
  name         = "${local.name}-duckdb-ui"
  user_pool_id = aws_cognito_user_pool.main.id

  # Confidential client: the code-for-token exchange happens in Lambda@Edge, never in the browser.
  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = ["https://${aws_cloudfront_distribution.ui.domain_name}/_auth/callback"]
  logout_urls                          = ["https://${aws_cloudfront_distribution.ui.domain_name}/"]
  explicit_auth_flows                  = ["ALLOW_REFRESH_TOKEN_AUTH"]
  prevent_user_existence_errors        = "ENABLED"
  enable_token_revocation              = true

  id_token_validity      = 60
  access_token_validity  = 60
  refresh_token_validity = 12
  token_validity_units {
    id_token      = "minutes"
    access_token  = "minutes"
    refresh_token = "hours"
  }
}

resource "aws_cognito_managed_login_branding" "ui" {
  user_pool_id                = aws_cognito_user_pool.main.id
  client_id                   = aws_cognito_user_pool_client.ui.id
  use_cognito_provided_values = true
}

resource "aws_cognito_user" "admin" {
  user_pool_id             = aws_cognito_user_pool.main.id
  username                 = var.admin_email
  desired_delivery_mediums = ["EMAIL"]

  attributes = {
    email          = var.admin_email
    email_verified = true
  }

  # Cognito emails a temporary password; it never goes through Terraform.
  lifecycle {
    ignore_changes = [attributes]
  }
}
