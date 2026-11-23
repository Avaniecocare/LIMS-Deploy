# ---------------------------------------------------------------- where
variable "region" {
  description = "Primary region (Mumbai)."
  type        = string
  default     = "ap-south-1"
}

variable "dr_region" {
  description = "Region for disaster copies (Hyderabad). Turn it on first: it is an opt-in region."
  type        = string
  default     = "ap-south-2"
}

variable "azs" {
  description = "Two availability zones in the primary region."
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b"]
  validation {
    condition     = length(var.azs) == 2
    error_message = "Exactly two availability zones."
  }
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

# ---------------------------------------------------------------- companies
variable "labs" {
  description = <<-EOT
    One entry per company. The key is its short name (slug: lower-case letters, digits and hyphens, at most 20).
      number      1-99, unique and never reused: its routing priority
      domain      the app's address; the API is api.<domain>
      dns_zone_id Route 53 hosted zone that holds the domain, or null when DNS is elsewhere (add the records by hand)
  EOT
  type = map(object({
    number      = number
    domain      = string
    dns_zone_id = optional(string)
  }))
  default = {}
  validation {
    condition     = alltrue([for k, v in var.labs : can(regex("^[a-z][a-z0-9-]{1,19}$", k)) && v.number >= 1 && v.number <= 99])
    error_message = "Each lab needs a slug of 2-20 lower-case letters, digits or hyphens, and a number from 1 to 99."
  }
  validation {
    condition     = length(distinct([for v in values(var.labs) : v.number])) == length(var.labs)
    error_message = "Every lab needs its own number."
  }
}

# ---------------------------------------------------------------- sizes and versions
variable "rds_engine_version" {
  description = "PostgreSQL version; the app is tested on 18."
  type        = string
  default     = "18"
}

variable "rds_instance_class" {
  type    = string
  default = "db.t4g.small"
}

variable "rds_connection_alarm" {
  description = "db.t4g.small allows about 180."
  type        = number
  default     = 130
}

variable "rds_allocated_storage_gb" {
  type    = number
  default = 50
}

variable "rds_max_storage_gb" {
  type    = number
  default = 200
}

variable "eks_version" {
  description = "Kubernetes version. 1.36 has standard support until 2 August 2027. Upgrade before that: extended support costs US$0.50 an hour more."
  type        = string
  default     = "1.36"
}

variable "node_instance_type" {
  description = "ARM. Each company needs about 1.5 GB of memory at rest (API x2, worker, screens x2, cache)."
  type        = string
  default     = "t4g.large"
}

variable "node_min" {
  type    = number
  default = 2
  validation {
    condition     = var.node_min >= 2
    error_message = "At least two nodes, one in each availability zone."
  }
}

variable "node_max" {
  type    = number
  default = 4
}

variable "nat_gateways" {
  description = "1, or 2 to keep outgoing calls (GST portal, email, WhatsApp) working when an availability zone fails."
  type        = number
  default     = 1
  validation {
    condition     = contains([1, 2], var.nat_gateways)
    error_message = "1 or 2."
  }
}

variable "admin_cidrs" {
  description = "Networks administrators reach the Kubernetes API from. Empty: from inside the VPC only."
  type        = list(string)
  default     = []
  validation {
    condition     = !contains(var.admin_cidrs, "0.0.0.0/0")
    error_message = "Name your own networks: the Kubernetes API must not be open to everyone."
  }
}

variable "cluster_admin_role_arns" {
  description = "IAM roles (from Identity Center) whose people administer the cluster."
  type        = list(string)
}

# ---------------------------------------------------------------- releases
variable "github_org" {
  description = "GitHub owner of the app repositories, for the CI role's trust."
  type        = string
}

variable "github_repos" {
  description = "Which repository may push which image."
  type        = map(string)
  default     = { lims = "LIMS", lims-ui = "LIMS-UI" }
}

# ---------------------------------------------------------------- protection and alerts
variable "waf_block" {
  description = "false = the web firewall only counts (first week); true = it blocks."
  type        = bool
  default     = false
}

variable "enable_backup_vault_lock" {
  description = "Compliance-mode lock on the Hyderabad vault. After the cooling-off days it can never be removed. Set true only once retention is agreed."
  type        = bool
  default     = false
}

variable "vault_lock_cooling_off_days" {
  type    = number
  default = 3
}

variable "oncall_emails" {
  description = "Addresses that receive alarms (confirm the subscription email). Add SMS or a paging service on the topics by hand."
  type        = list(string)
}

variable "budget_monthly_usd" {
  type    = number
  default = 450
}

variable "budget_emails" {
  type = list(string)
}

variable "log_retention_days" {
  description = "CERT-In asks for 180 days."
  type        = number
  default     = 180
}
