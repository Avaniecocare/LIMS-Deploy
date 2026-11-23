# Step 5: private image registry, and a role per repository that GitHub Actions assumes through OIDC to push releases
# (no stored keys).

resource "aws_ecr_repository" "app" {
  for_each             = toset(["lims", "lims-ui"])
  name                 = each.key
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "KMS" }
}

# Releases (tags that start with a digit) are never swept: a company may be running any of them.
resource "aws_ecr_lifecycle_policy" "app" {
  for_each   = aws_ecr_repository.app
  repository = each.value.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Untagged images after 30 days"
        selection    = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 30 }
        action       = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "The last 30 builds that are not releases"
        selection    = { tagStatus = "tagged", tagPrefixList = ["sha-"], countType = "imageCountMoreThan", countNumber = 30 }
        action       = { type = "expire" }
      },
    ]
  })
}

locals {
  ci_subjects = { for image, repo in var.github_repos : image => "repo:${var.github_org}/${repo}:ref:refs/tags/v*" }
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

resource "aws_iam_role" "ci_push" {
  for_each = var.github_repos
  name     = "lims-ci-push-${each.key}"
  # The repositories are public: this condition (that repository, release tags only) is what keeps anyone else out.
  # Protect v* tags in GitHub as well.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike   = { "token.actions.githubusercontent.com:sub" = local.ci_subjects[each.key] }
      }
    }]
  })
}

resource "aws_iam_role_policy" "ci_push" {
  for_each = var.github_repos
  role     = aws_iam_role.ci_push[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
      {
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:DescribeImages"]
        Resource = aws_ecr_repository.app[each.key].arn
      },
    ]
  })
}
