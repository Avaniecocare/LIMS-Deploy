terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
  # Settings in backend.hcl (see backend.hcl.example): terraform init -backend-config=backend.hcl
  backend "s3" {}
}

locals {
  tags       = { Project = "lims", Environment = "prod", ManagedBy = "terraform" }
  account_id = data.aws_caller_identity.me.account_id
}

# Mumbai: the server.
provider "aws" {
  region = var.region
  default_tags { tags = local.tags }
}

# Hyderabad: the off-site copies of the backups.
provider "aws" {
  alias  = "dr"
  region = var.dr_region
  default_tags { tags = local.tags }
}

# Route 53 health check metrics exist only in us-east-1, so their alarms and topic live there.
provider "aws" {
  alias  = "use1"
  region = "us-east-1"
  default_tags { tags = local.tags }
}

data "aws_caller_identity" "me" {}
