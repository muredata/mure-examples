variable "region" {
  description = "AWS Region for the VPC, S3 Tables, ECS and Cognito. Must support S3 Tables and CloudFront VPC origins."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-\\d$", var.region))
    error_message = "region must be an AWS Region name such as eu-west-1."
  }
}

variable "project" {
  description = "Name prefix for every resource. Lowercase letters, digits and hyphens."
  type        = string
  default     = "duckdemo"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.project))
    error_message = "project must be 3-21 characters: lowercase letters, digits and hyphens."
  }
}

variable "admin_email" {
  description = "Email of the demo admin user. Cognito emails it a temporary password."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.admin_email))
    error_message = "admin_email must be an email address."
  }
}

variable "allowed_cidrs" {
  description = "Client IP ranges (IPv4 and/or IPv6 CIDRs) allowed through the WAF. Everything else is blocked."
  type        = list(string)

  validation {
    condition     = length(var.allowed_cidrs) > 0 && alltrue([for c in var.allowed_cidrs : can(cidrnetmask(c)) || can(regex("^[0-9a-fA-F:]+/[0-9]{1,3}$", c))])
    error_message = "allowed_cidrs needs at least one valid CIDR, for example [\"203.0.113.10/32\"]."
  }

  validation {
    condition     = !contains(var.allowed_cidrs, "0.0.0.0/0") && !contains(var.allowed_cidrs, "::/0")
    error_message = "Opening the SQL console to the whole internet is not allowed; list the client ranges that need access."
  }
}

variable "mfa_configuration" {
  description = "Cognito MFA: OPTIONAL (users may enrol an authenticator app) or ON (required for every user)."
  type        = string
  default     = "OPTIONAL"

  validation {
    condition     = contains(["OPTIONAL", "ON"], var.mfa_configuration)
    error_message = "mfa_configuration must be OPTIONAL or ON."
  }
}

variable "vpc_cidr" {
  description = "CIDR of the demo VPC."
  type        = string
  default     = "10.40.0.0/16"
}

variable "az_count" {
  description = "Availability Zones to use (the internal ALB needs at least 2)."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "nat_gateway_per_az" {
  description = "One NAT gateway per AZ (resilient) instead of one shared NAT gateway (cheaper)."
  type        = bool
  default     = false
}

variable "tpcds_namespace" {
  description = "S3 Tables namespace for the TPC-DS tables (read-only for the UI)."
  type        = string
  default     = "tpcds"
}

variable "sandbox_namespace" {
  description = "S3 Tables namespace where UI users may create and change tables."
  type        = string
  default     = "sandbox"
}

# --- DuckDB UI service sizing (AWS Fargate, Graviton) ---------------------------------

variable "ui_cpu" {
  description = "vCPU units for the DuckDB UI task (8192 = 8 vCPU)."
  type        = number
  default     = 8192
}

variable "ui_memory" {
  description = "Memory (MiB) for the DuckDB UI task. 8 vCPU allows 16-60 GiB."
  type        = number
  default     = 32768
}

variable "ui_duckdb_memory_limit" {
  description = "DuckDB memory_limit for the UI. Keep about 25% of task memory free for the process, HTTP buffers and the proxy."
  type        = string
  default     = "24GB"
}

variable "ui_ephemeral_storage_gib" {
  description = "Fargate ephemeral storage for the UI task: DuckDB spill files and the local workspace database."
  type        = number
  default     = 100
}

variable "ui_desired_count" {
  description = "Number of UI tasks. 1 while the demo runs, 0 to stop paying for compute. Ignored until images are pushed."
  type        = number
  default     = 1

  validation {
    condition     = contains([0, 1], var.ui_desired_count)
    error_message = "ui_desired_count must be 0 or 1 (the UI keeps notebooks on the task's local storage)."
  }
}

# --- TPC-DS loader (one-off Fargate task) ------------------------------------------------

variable "loader_cpu" {
  description = "vCPU units for the TPC-DS loader task (16384 = 16 vCPU)."
  type        = number
  default     = 16384
}

variable "loader_memory" {
  description = "Memory (MiB) for the loader task."
  type        = number
  default     = 65536
}

variable "loader_duckdb_memory_limit" {
  description = "DuckDB memory_limit for the loader."
  type        = string
  default     = "48GB"
}

variable "loader_ephemeral_storage_gib" {
  description = "Ephemeral storage for the loader: the generated SF10 database plus spill space."
  type        = number
  default     = 200
}

# --- Images (written by `uv run duckdemo deploy` into images.auto.tfvars.json) ------------

variable "duckdb_image_tag" {
  description = "Tag of the DuckDB image in ECR. Empty until the first push; the UI service stays at 0 tasks until then."
  type        = string
  default     = ""
}

variable "proxy_image_tag" {
  description = "Tag of the proxy image in ECR."
  type        = string
  default     = ""
}

# --- Edge and operations ---------------------------------------------------------------

variable "origin_read_timeout" {
  description = "CloudFront origin read timeout in seconds (max 60 without a quota increase; up to 180 with one). Long queries need more."
  type        = number
  default     = 60
}

variable "waf_rate_limit" {
  description = "Requests per 5 minutes allowed per client IP before WAF blocks it. The UI polls, so keep this generous."
  type        = number
  default     = 6000
}

variable "log_retention_days" {
  description = "Retention for every CloudWatch log group."
  type        = number
  default     = 30
}

variable "enable_execute_command" {
  description = "Allow `aws ecs execute-command` into the UI task (for troubleshooting). Gated by IAM."
  type        = bool
  default     = false
}

variable "force_destroy" {
  description = "Let `terraform destroy` delete the table bucket, ECR images and log buckets with their contents. Demo only."
  type        = bool
  default     = true
}
