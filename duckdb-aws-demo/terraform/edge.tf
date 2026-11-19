# Lambda@Edge viewer-request function (us-east-1) that enforces the Cognito login.
# Source: ../edge-auth (bundled with esbuild by `uv run duckdemo deploy`).
#
# Lambda@Edge has no environment variables, so the configuration lives in a Secrets
# Manager secret named "<function>/config" (in us-east-1), read and cached by the function.
# It contains the app client secret and the CSRF nonce signing key.

locals {
  edge_function_name = "${local.name}-edge-auth"
}

data "archive_file" "edge_auth" {
  type        = "zip"
  source_file = "${path.module}/../edge-auth/dist/index.js"
  output_path = "${path.module}/.build/edge-auth.zip"
}

data "aws_iam_policy_document" "edge_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com", "edgelambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "edge_auth" {
  name               = local.edge_function_name
  assume_role_policy = data.aws_iam_policy_document.edge_assume.json
}

data "aws_iam_policy_document" "edge_auth" {
  statement {
    sid       = "ReadOwnConfig"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.edge_config.arn]
  }
  # Replicas log to "/aws/lambda/us-east-1.<function>" in the Region that served the request.
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:${local.partition}:logs:*:${local.account_id}:log-group:/aws/lambda/*${local.edge_function_name}:*"]
  }
}

resource "aws_iam_role_policy" "edge_auth" {
  name   = "config-and-logs"
  role   = aws_iam_role.edge_auth.id
  policy = data.aws_iam_policy_document.edge_auth.json
}

resource "aws_lambda_function" "edge_auth" {
  provider         = aws.us_east_1
  function_name    = local.edge_function_name
  description      = "Cognito login gate for the DuckDB UI (viewer request)"
  role             = aws_iam_role.edge_auth.arn
  runtime          = "nodejs24.x"
  architectures    = ["x86_64"]
  handler          = "index.handler"
  filename         = data.archive_file.edge_auth.output_path
  source_code_hash = data.archive_file.edge_auth.output_base64sha256
  memory_size      = 256
  timeout          = 5
  publish          = true

  depends_on = [aws_iam_role_policy.edge_auth]
}

resource "random_password" "csrf_signing" {
  length  = 48
  special = false
}

resource "aws_secretsmanager_secret" "edge_config" {
  provider                = aws.us_east_1
  name                    = "${local.edge_function_name}/config"
  description             = "Cognito settings for the Lambda@Edge login gate"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "edge_config" {
  provider  = aws.us_east_1
  secret_id = aws_secretsmanager_secret.edge_config.id
  secret_string = jsonencode({
    region             = var.region
    userPoolId         = aws_cognito_user_pool.main.id
    userPoolAppId      = aws_cognito_user_pool_client.ui.id
    userPoolAppSecret  = aws_cognito_user_pool_client.ui.client_secret
    userPoolDomain     = "${aws_cognito_user_pool_domain.main.domain}.auth.${var.region}.amazoncognito.com"
    nonceSigningSecret = random_password.csrf_signing.result
  })
}
