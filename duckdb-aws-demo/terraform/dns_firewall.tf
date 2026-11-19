# Route 53 Resolver DNS Firewall: the VPC can only resolve AWS service names and the
# DuckDB UI frontend host. Everything else gets NXDOMAIN, so DuckDB can't fetch URLs by
# name (read_csv('https://example.com/...')) through the NAT gateway.
# This is a guard rail, not a hard egress boundary: a literal IP address still reaches
# the internet on port 443. The hard boundary is WAF + Cognito in front of the UI.

resource "aws_route53_resolver_firewall_domain_list" "allowed" {
  name = "${local.name}-allowed"
  domains = [
    "ui.duckdb.org.",   # DuckDB UI frontend, proxied by the ui extension at runtime
    "*.amazonaws.com.", # AWS service endpoints (resolve to the VPC endpoints)
    "*.amazonaws.com.cn.",
    "*.api.aws.",          # dual-stack AWS endpoints
    "*.compute.internal.", # VPC-internal names
    "*.ec2.internal.",
  ]
}

resource "aws_route53_resolver_firewall_domain_list" "everything" {
  name    = "${local.name}-everything"
  domains = ["*."]
}

resource "aws_route53_resolver_firewall_rule_group" "main" {
  name = "${local.name}-egress"
}

resource "aws_route53_resolver_firewall_rule" "allow" {
  name   = "allow-required"
  action = "ALLOW"
  # ui.duckdb.org is a CNAME to a *.cloudfront.net name. By default DNS Firewall also
  # checks every CNAME target, which the block rule would reject. Trust the redirection
  # chain only when it starts from an allowed name.
  firewall_domain_redirection_action = "TRUST_REDIRECTION_DOMAIN"
  firewall_domain_list_id            = aws_route53_resolver_firewall_domain_list.allowed.id
  firewall_rule_group_id             = aws_route53_resolver_firewall_rule_group.main.id
  priority                           = 100
}

resource "aws_route53_resolver_firewall_rule" "block" {
  name                    = "block-everything-else"
  action                  = "BLOCK"
  block_response          = "NXDOMAIN"
  firewall_domain_list_id = aws_route53_resolver_firewall_domain_list.everything.id
  firewall_rule_group_id  = aws_route53_resolver_firewall_rule_group.main.id
  priority                = 200
}

resource "aws_route53_resolver_firewall_rule_group_association" "main" {
  name                   = "${local.name}-egress"
  firewall_rule_group_id = aws_route53_resolver_firewall_rule_group.main.id
  vpc_id                 = aws_vpc.main.id
  priority               = 101
}

# Fail closed if the DNS Firewall itself is unavailable.
resource "aws_route53_resolver_firewall_config" "main" {
  resource_id        = aws_vpc.main.id
  firewall_fail_open = "DISABLED"
}
