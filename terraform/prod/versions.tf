terraform {
  required_version = ">= 1.10"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 6.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
  # Settings in backend.hcl (see backend.hcl.example): terraform init -backend-config=backend.hcl
  backend "s3" {}
}

locals {
  tags = { Project = "lims", Environment = "prod", ManagedBy = "terraform" }
}

# Mumbai: everything that serves the labs.
provider "aws" {
  region = var.region
  default_tags { tags = local.tags }
}

# Hyderabad: disaster copies (backup vault, replica buckets).
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
data "aws_partition" "current" {}
