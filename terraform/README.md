# Production on AWS (Terraform)

| | [server/](server/README.md) | prod/ |
| --- | --- | --- |
| What | One ARM server, Docker Compose | Kubernetes (EKS) over two zones, PostgreSQL Multi-AZ, load balancer with a web firewall |
| Companies | Up to about 5 | More, with a namespace, identity and bucket each |
| If a machine or zone fails | Restarted by AWS, or rebuilt by hand in an hour or two | Carries on |
| US dollars a month | About 85-165 | About 340-380, and more per company |

Use `server/` while the budget is 200 a month: EKS's control plane, load balancer, NAT gateway and Multi-AZ database alone cost more than that before a single node. Moving later means restoring each company's backup into the other.

**Nothing here has been applied to a real account yet.** It is validated and planned against mocked AWS only.

The rest of this page is what the two share, and `prod/`: AWS Mumbai (`ap-south-1`) with disaster copies in Hyderabad (`ap-south-2`), one S3 bucket per company with versioning, Object Lock and a Hyderabad copy, AWS Backup, alarms, and a role per repository that pushes images. What runs in the cluster is in [../kubernetes](../kubernetes/README.md). Adding a company: [../docs/aws/companies.md](../docs/aws/companies.md).

## Layout

| Path | What it is |
| --- | --- |
| `bootstrap/` | Run once: the S3 bucket that holds the state |
| `account/` | Run once: CloudTrail, GuardDuty, Access Analyzer and the budget, for either setup |
| `server/` | One server, with Docker Compose |
| `prod/` | Kubernetes |
| `modules/lab/` | A company's buckets, secrets, pods' identity, routing, uptime checks and alarms |
| `*/tests/` | `terraform test`: plans each setup against mocked AWS, no account needed |

| File in `prod/` | What and why |
| --- | --- |
| `network.tf` | VPC, subnets, NAT, S3 endpoint, flow logs, security groups. The database has no internet route at all |
| `eks.tf` | The cluster, its nodes, its add-ons, and the AWS roles of what runs in it |
| `data.tf` | RDS |
| `ci.tf` | ECR, and who may push which image |
| `edge.tf`, `certificates.tf` | Load balancer, access logs, web firewall, one certificate per company |
| `labs.tf` | One `modules/lab` per company |
| `backup.tf`, `monitoring.tf` | AWS Backup, alarms |

## Done by hand, not here

- Root user MFA, IAM Identity Center and the people in it.
- Turning on the Hyderabad region.
- Sending email: verify a domain in Amazon SES, or use an SMTP service.
- Integration secrets, added to each company's secret so they never enter the state.
- SMS or phone paging on the `lims-oncall` topics. Terraform subscribes the email addresses only.
- Protecting `v*` tags in the GitHub repositories: whoever can make one can push an image.

## First time

```sh
# Credentials: an Identity Center admin session
cd terraform/bootstrap && terraform init && terraform apply
cd ../account                                       # then the same four lines in ../server, or in ../prod
cp backend.hcl.example backend.hcl                  # fill in the account id
cp terraform.tfvars.example terraform.tfvars        # fill in; real values stay out of git
terraform init -backend-config=backend.hcl
terraform plan -out=tfplan && terraform apply tfplan
```

<a id="kubernetes"></a>For `prod/`, once per cluster, what the manifests rely on:

```sh
aws eks update-kubeconfig --name lims-prod --region ap-south-1
kubectl apply -f ../../kubernetes/cluster/storage-class.yaml
helm install aws-load-balancer-controller aws-load-balancer-controller --repo https://aws.github.io/eks-charts --version 3.6.3 -n kube-system \
  --set clusterName=lims-prod --set region=ap-south-1 --set vpcId=<vpc id> --set serviceAccount.name=aws-load-balancer-controller
helm install external-secrets external-secrets --repo https://charts.external-secrets.io --version 2.15.0 -n external-secrets --create-namespace
kubectl apply -f ../../kubernetes/cluster/secret-store.yaml
```

## Things that cannot be undone

| Setting | Why it is permanent |
| --- | --- |
| `enable_backup_vault_lock = true` | After the cooling-off days the Hyderabad vault's lock can never be removed, and its 7-year copies are paid for 7 years |
| Object Lock on a company's buckets | Can only be set at creation, and stays |
| `prevent_destroy` on buckets, `deletion_protection` on RDS, the cluster and the load balancer | Deliberate: removing a company's data is a separate, written decision |

## Secrets

Database passwords, session secrets, cache passwords and setup tokens are ephemeral values written straight to Secrets Manager (Terraform 1.11 or later): they are in neither the plan nor the state. The database's master password is RDS's own.

## Checking changes without an AWS account

```sh
cd terraform/server      # or account, or prod
terraform fmt -recursive -check ..
terraform init -backend=false && terraform validate && terraform test
```

With no local Terraform: `docker run --rm -v "$PWD/..:/w" -w /w/server hashicorp/terraform:1.13 test`.

## Cost of `prod/`

US dollars a month for the first company, on demand, 730 hours, from AWS's Mumbai price list of 1 November 2026:

| | | |
| --- | --- | --- |
| Kubernetes control plane | 0.10 an hour | 73 |
| 2 nodes, `t4g.large` | 0.0448 an hour each | 65 |
| Node disks, 2 × 60 GB | 0.0912 a GB | 11 |
| PostgreSQL `db.t4g.small` Multi-AZ | 0.084 an hour | 61 |
| Its storage, 50 GB Multi-AZ | 0.262 a GB | 13 |
| NAT gateway, 50 GB a month through it | 0.056 an hour and a GB | 44 |
| Load balancer, about 1 capacity unit | 0.0239 and 0.008 an hour | 23 |
| **From the price list** | | **290** |
| Assumed: 3 public addresses at 0.005 an hour | | 11 |
| Assumed: web firewall, logs, alarms, health checks, backups, files | | 40–80 |
| **About** | | **340–380** |

Not included: tax, email, data out, the support plan. Another company adds files, secrets, two health checks and alarms, and a node (about 38) for roughly every four. A second NAT gateway adds about 41. The nodes and database can be reserved for a year for less. Confirm in the AWS Pricing Calculator.
