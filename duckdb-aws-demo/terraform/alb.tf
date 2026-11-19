# Internal ALB in the private subnets. Its only client is CloudFront, through a
# CloudFront VPC origin (service-managed ENIs in the private subnets).
#
# CloudFront -> ALB is HTTP inside the VPC because the ALB has no custom domain or
# certificate. With a Route 53 domain, add an ACM certificate and an HTTPS listener and
# set origin_protocol_policy = "https-only" in cloudfront.tf.

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Internal ALB: HTTP from CloudFront VPC origin only"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_cloudfront" {
  security_group_id = aws_security_group.alb.id
  description       = "CloudFront origin-facing ranges (VPC origin ENIs)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
}

resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  security_group_id            = aws_security_group.alb.id
  description                  = "To the proxy sidecar"
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = aws_security_group.tasks.id
}

resource "aws_lb" "ui" {
  name                       = "${local.name}-ui"
  internal                   = true
  load_balancer_type         = "application"
  subnets                    = aws_subnet.private[*].id
  security_groups            = [aws_security_group.alb.id]
  drop_invalid_header_fields = true
  # Long enough for the UI's server-sent events stream.
  idle_timeout               = 300
  enable_deletion_protection = false
}

resource "aws_lb_target_group" "ui" {
  name                 = "${local.name}-ui"
  vpc_id               = aws_vpc.main.id
  target_type          = "ip"
  protocol             = "HTTP"
  port                 = 8080
  deregistration_delay = 30

  health_check {
    path                = "/healthz"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "ui" {
  load_balancer_arn = aws_lb.ui.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ui.arn
  }
}
