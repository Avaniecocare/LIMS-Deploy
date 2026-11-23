variable "slug" {
  description = "The company's short name: lower-case letters, digits and hyphens."
  type        = string
}

variable "number" {
  description = "1-99, unique, never reused: listener rule priority."
  type        = number
}

variable "domain" {
  description = "The app's address; the API is api.<domain>."
  type        = string
}

variable "dns_zone_id" {
  description = "Route 53 hosted zone for the domain, or null when DNS is elsewhere (records added by hand)."
  type        = string
  default     = null
}

variable "account_id" {
  type = string
}

variable "region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "listener_arn" {
  description = "The HTTPS listener (it exists whenever at least one company does)."
  type        = string
}

variable "certificate_arn" {
  description = "The company's issued certificate (created at the top level, so the listener can use it)."
  type        = string
}

variable "is_default_certificate" {
  description = "This company's certificate is the listener's default (so it is not added a second time)."
  type        = bool
}

variable "alb_arn_suffix" {
  type = string
}

variable "alb_dns_name" {
  type = string
}

variable "alb_zone_id" {
  type = string
}

variable "rds_address" {
  type = string
}

variable "alarm_topic_arn" {
  type = string
}

variable "alarm_topic_use1_arn" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "pod_identity_trust" {
  description = "The trust policy that lets a pod in this account's clusters take a role."
  type        = string
}

variable "secrets_version" {
  description = "Raise to make new secrets."
  type        = number
  default     = 1
}
