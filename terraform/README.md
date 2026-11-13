# Production on AWS (Terraform)

The setup from the production plan and runbook, as code: AWS Mumbai (`ap-south-1`) with disaster copies in
Hyderabad (`ap-south-2`). Two app servers in two data centres behind a load balancer, PostgreSQL on RDS Multi-AZ,
Valkey on ElastiCache with a replica, one S3 bucket per company with versioning, Object Lock and a Hyderabad copy,
AWS Backup, alarms, and the CI role that pushes images.

Adding a company is one entry in `labs` and an apply: see [docs/aws/companies.md](../docs/aws/companies.md).

## Layout

| Path | What it is |
| --- | --- |
| `bootstrap/` | Run once: the S3 bucket that holds the state |
| `prod/` | Everything else; run from here |
| `prod/certificates.tf` | One certificate per company |
| `prod/labs.tf` | One `modules/lab` per company, and the company list the servers read |
| `modules/lab/` | A company's buckets, settings (SSM), routing, uptime checks and alarms |
| `prod/tests/` | `terraform test`: plans the whole setup against mocked AWS, no account needed |

| File in `prod/` | Runbook step |
| --- | --- |
| `account.tf` | 1: CloudTrail, GuardDuty, Access Analyzer, budget |
| `network.tf` | 2: VPC, subnets, S3 endpoint, flow logs, security groups |
| `data.tf` | 3: RDS and ElastiCache |
| `ci.tf` | 5: ECR and the GitHub Actions role |
| `app.tf`, `user-data.sh.tftpl` | 4 and 6: server role, launch template, Auto Scaling group |
| `edge.tf` | 7: load balancer, access logs, web firewall |
| `backup.tf`, `monitoring.tf` | 9: AWS Backup, alarms |

## Done by hand, not here

- Root user MFA, IAM Identity Center and the people in it.
- Turning on the Hyderabad region (opt-in, Account settings).
- Sending email: verify a domain in Amazon SES, or use an SMTP service.
- Integration secrets (SMTP password, WhatsApp, e-invoicing): `aws ssm put-parameter --type SecureString` under
  `/lims/prod/<slug>/`, so they never enter the Terraform state.
- Each company's database and roles (inside the private RDS, unreachable from a laptop): see the companies guide.
- SMS or phone paging on the `lims-oncall` topics. Terraform subscribes the email addresses only.

## First time

```bash
# 0. Credentials: an Identity Center admin session, e.g. aws sso login --profile lims-prod; export AWS_PROFILE=lims-prod
cd terraform/bootstrap && terraform init && terraform apply           # the state bucket
cd ../prod
cp backend.hcl.example backend.hcl                                     # fill in the account id
cp terraform.tfvars.example terraform.tfvars                           # fill in; real values stay out of git
terraform init -backend-config=backend.hcl
terraform plan -out=tfplan && terraform apply tfplan
```

Keep `app_servers_enabled = false` until the eight app changes in the runbook are released (the servers' start-up
script calls `scripts/aws/start-labs.sh`, which those changes add). Everything else can be built and checked before.

## Things that cannot be undone

| Setting | Why it is permanent |
| --- | --- |
| `enable_backup_vault_lock = true` | After `vault_lock_cooling_off_days` the Hyderabad vault's lock can never be removed, not even by the root user, and its 7-year copies are paid for 7 years |
| Object Lock on a company's buckets | Always on (it can only be set at creation). PDFs the app locks cannot be deleted until their date |
| `prevent_destroy` on buckets, `deletion_protection` on RDS and the load balancer | Deliberate: removing a company's data is a separate, written decision (companies guide, "Remove a company") |

## The state holds secrets

The database passwords, session secrets, setup tokens and the cache's token are generated here and kept in the
state, which lives encrypted in the versioned state bucket. Only the administrators who run Terraform may read that
bucket. Never copy state files elsewhere.

## Checking changes without an AWS account

```bash
cd terraform/prod
terraform fmt -recursive -check ..
terraform init -backend=false && terraform validate && terraform test
```

With no local Terraform, Docker works the same: `docker run --rm -v "$PWD/..:/w" -w /w/prod hashicorp/terraform:1.13 test`.

## Sizes and cost

The defaults (`t4g.medium` ×2, `db.t4g.small` Multi-AZ, `cache.t4g.micro` ×2) cost roughly US$190–240 a month on
demand in Mumbai for the first company; see the production plan. Confirm in the AWS Pricing Calculator.
