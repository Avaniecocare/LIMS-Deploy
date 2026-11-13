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
      number      1-15, unique and never reused: its Redis database, host ports 8100+n / 3100+n and listener priority
      domain      the app's address; the API is api.<domain>
      dns_zone_id Route 53 hosted zone that holds the domain, or null when DNS is elsewhere (add the records by hand)
      image_tag   the release the company runs (an ECR tag, e.g. "1.4.0")
  EOT
  type = map(object({
    number      = number
    domain      = string
    dns_zone_id = optional(string)
    image_tag   = string
  }))
  default = {}
  validation {
    condition     = alltrue([for k, v in var.labs : can(regex("^[a-z][a-z0-9-]{1,19}$", k)) && v.number >= 1 && v.number <= 15])
    error_message = "Each lab needs a slug of 2-20 lower-case letters, digits or hyphens, and a number from 1 to 15."
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

variable "rds_allocated_storage_gb" {
  type    = number
  default = 50
}

variable "rds_max_storage_gb" {
  type    = number
  default = 200
}

variable "cache_engine" {
  type    = string
  default = "valkey"
}

variable "cache_engine_version" {
  type    = string
  default = "8.0"
}

variable "cache_parameter_family" {
  type    = string
  default = "valkey8"
}

variable "cache_node_type" {
  type    = string
  default = "cache.t4g.micro"
}

variable "app_instance_type" {
  type    = string
  default = "t4g.medium"
}

variable "app_servers_enabled" {
  description = "Start the two app servers. Leave false until the app changes in the runbook are released; the servers would not become healthy before."
  type        = bool
  default     = false
}

variable "compose_version" {
  description = "Docker Compose plugin release installed on the servers."
  type        = string
  default     = "v2.29.7"
}

# ---------------------------------------------------------------- releases
variable "deploy_repo_url" {
  description = "Git URL of LIMS-Deploy, cloned by each server at start."
  type        = string
}

variable "deploy_version" {
  description = "The LIMS-Deploy tag the servers use."
  type        = string
}

variable "github_org" {
  description = "GitHub owner of the app repositories, for the CI role's trust."
  type        = string
}

variable "github_repos" {
  description = "Repositories allowed to push images."
  type        = list(string)
  default     = ["LIMS", "LIMS-UI"]
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
  default = 300
}

variable "budget_emails" {
  type = list(string)
}

variable "log_retention_days" {
  description = "CERT-In asks for 180 days."
  type        = number
  default     = 180
}
