variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "dr_region" {
  description = "Where the off-site backups are kept. Turn it on first: Hyderabad is an opt-in region."
  type        = string
  default     = "ap-south-2"
}

variable "availability_zone" {
  type    = string
  default = "ap-south-1a"
}

variable "vpc_cidr" {
  type    = string
  default = "10.30.0.0/24"
}

variable "instance_type" {
  description = "ARM only (t4g, m7g, ...). A company uses about 2.8 GB: t4g.large (8 GB) for 1-2 companies, t4g.xlarge (16 GB) for 3-5."
  type        = string
  default     = "t4g.large"
  validation {
    condition     = can(regex("^[a-z]+[0-9]+g[a-z]*\\.", var.instance_type))
    error_message = "The server image is ARM: choose a Graviton type such as t4g.large."
  }
}

variable "data_disk_gb" {
  description = "Databases, files, images and local backups. It can grow later, never shrink."
  type        = number
  default     = 100
}

variable "data_snapshot_id" {
  description = "Only when rebuilding from a snapshot of the data disk: its id. See the README."
  type        = string
  default     = null
}

variable "health_check_hosts" {
  description = "Each company's API host, watched from outside (about 1.5 US dollars a month each). Example: [\"api.lims.example.com\"]."
  type        = set(string)
  default     = []
}

variable "oncall_emails" {
  description = "Addresses that receive alarms (confirm the subscription email)."
  type        = list(string)
}

variable "backup_lock_days" {
  description = "For this many days nobody, an administrator included, can delete an off-site backup."
  type        = number
  default     = 30
}

variable "backup_keep_days" {
  type    = number
  default = 90
  validation {
    condition     = var.backup_keep_days >= var.backup_lock_days
    error_message = "Backups cannot be removed while they are locked: keep them at least as long."
  }
}
