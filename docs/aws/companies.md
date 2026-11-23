# Companies on AWS

How to put the first company on production, add each one after it, and take one off. Each company gets its own namespace, database and roles, file bucket with a copy in Hyderabad, secrets, cache, identity, address, certificate and alarms. They share the cluster's nodes, the database instance and the load balancer.

## Names

| Name | Example | Rule |
| --- | --- | --- |
| `<slug>` | `acme` | Lower-case letters, digits and hyphens, 2–20 characters. Never changed later |
| `<n>` | `1` | 1–99, unique, **never reused**: its routing priority |
| `<domain>` | `lims.acme.example` | The app's address. The API is `api.<domain>` |

## Add a company

### 1. Terraform

```hcl
labs = {
  acme = { number = 1, domain = "lims.acme.example", dns_zone_id = null } # or its Route 53 zone id
}
```

With DNS outside Route 53, request the certificate first and add its two proof records at the DNS provider:

```sh
terraform apply -target='aws_acm_certificate.lab["acme"]'
terraform output -json certificate_validation
```

Then apply. Read the plan: only this company's resources (and, for the first, the HTTPS listener) should be new.

```sh
terraform plan -out=tfplan && terraform apply tfplan
terraform output -json labs | jq .acme      # used below
```

With DNS elsewhere, add CNAME records for `<domain>` and `api.<domain>` to `load_balancer_dns`.

### 2. Its own secrets

Terraform made the database, session, cache and setup secrets, which are not in its state. Add what the company uses to the same secret, `lims/prod/acme/app`, in the Secrets Manager console or with `aws secretsmanager put-secret-value`: `SMTP_USER`, `SMTP_PASSWORD`, `LICENCE`, `WHATSAPP_*`, `EINVOICE_*`, `AI_API_KEY`. Keep the keys that are there.

### 3. Its database

```sh
kubernetes/create-database.sh acme --master-secret "$(terraform -chdir=terraform/prod output -raw rds_master_secret_arn)"
```

### 4. Install it

Copy `kubernetes/overlays/example` to a private place, fill in `company.properties` from the outputs, and follow [kubernetes/README.md](../../kubernetes/README.md#add-a-company).

### 5. First set-up

Read the setup token, open `https://<domain>`, and create the first administrator. It works only while the company has no users.

```sh
aws secretsmanager get-secret-value --secret-id lims/prod/acme/app --query SecretString --output text | jq -r .SETUP_TOKEN
```

### 6. Check

- [ ] The administrator signs in
- [ ] A logo uploads, and appears in the bucket and within 15 minutes in Hyderabad
- [ ] A PDF downloads (the worker, Chromium and S3)
- [ ] A test email arrives
- [ ] Both target groups have 2 healthy targets
- [ ] `aws cloudwatch describe-alarms --alarm-name-prefix lims-acme` are OK, and the Route 53 checks are green

## Take a company off

Removing data is a separate, written decision. Buckets carry `prevent_destroy`, secrets wait 30 days, and the database is left in place.

1. Give the company its data, and agree in writing what is kept and for how long.
2. `kubectl delete namespace lims-<slug>`
3. Take a final snapshot of the database instance, then drop the database and its two roles.
4. Remove the entry from `labs`. Terraform will refuse to delete the buckets: take them out of the state (`terraform state rm`) and keep or empty them as agreed.

Never reuse its number or slug.
