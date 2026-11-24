# One server on AWS

Every company on one ARM server in Mumbai, run with `../../compose` and `../../scripts` ([DEPLOYMENT.md](../../DEPLOYMENT.md)), with its backups in Hyderabad. The set-up for up to about five companies on a budget of 200 US dollars a month.

**Not yet applied to a real account.** It is validated and planned against mocked AWS, and the server's set-up script has been run on Ubuntu 24.04 for ARM: first start, a replaced server with the same data disk, and a missing data disk.

## What it gives, and what it does not

| | |
| --- | --- |
| Getting in | Ports 80 and 443 only. A shell is through Session Manager, with the person's own AWS identity |
| A failed machine | AWS moves the server to other hardware; a hung system is restarted |
| A lost zone, or a lost server | Rebuilt from a snapshot at most an hour old, by hand: plan for one to two hours |
| A lost region | Rebuilt from last night's copy in Hyderabad, by hand |
| A break-in on the server | It can add off-site backups, not read or delete them, and nobody can delete one for 30 days |
| Upgrades | A minute or two of downtime for the company being upgraded |
| No standby | When the server is down, every company on it is down. If that is not acceptable, [../prod](../README.md#kubernetes) is the answer, at its price |

## Cost

US dollars a month, on demand, 730 hours, from AWS's price list of 1 November 2026 (Mumbai, and Hyderabad for backups):

| | 1-2 companies | 3-5 companies |
| --- | --- | --- |
| Server: `t4g.large` 0.0448 or `t4g.xlarge` 0.0896 an hour | 33 | 65 |
| Disks at 0.0912 a GB: 130 GB or 230 GB | 12 | 21 |
| Public address, 0.005 an hour | 4 | 4 |
| Snapshots at 0.05 a GB, assuming 40 or 80 GB | 2 | 4 |
| Off-site backups at 0.025 a GB, assuming 5 or 10 GB a night kept 90 days | 11 | 23 |
| Sending them to Hyderabad, 0.086 a GB | 13 | 26 |
| Alarms, figures, outside checks | 5 | 10 |
| Assumed: audit trail, GuardDuty, state | 5-10 | 5-10 |
| **About** | **85-90** | **160-165** |

Not included: tax, email, the support plan, and downloads beyond 100 GB a month. Smaller or fewer off-site copies (`backup_keep_days`, or `dr_region` set to Mumbai, which has no transfer charge but shares a region with the server) and a one-year commitment lower it. The budget in `../account` emails at 50, 80 and 100%, and when the month is heading past 100%. AWS never stops anything by itself.

## First time

Run `../bootstrap` and `../account` first ([../README.md](../README.md#first-time)). Turn on the Hyderabad region. Then:

```sh
cp backend.hcl.example backend.hcl && cp terraform.tfvars.example terraform.tfvars    # fill in
terraform init -backend-config=backend.hcl
terraform plan -out=tfplan && terraform apply tfplan
terraform output
```

Give it about five minutes, then open a shell with the `open_a_shell` command and:

```sh
sudo -iu ubuntu
tail -1 /var/log/cloud-init-output.log                # LIMS server ready, or the error
git clone https://github.com/Avaniecocare/LIMS-Deploy.git /opt/lims-deploy
cd /opt/lims-deploy/proxy && PROXY_SITES_DIR=/srv/lims-proxy/sites docker compose up -d
```

Images: `docker login ghcr.io`, or upload the files you were sent and load them:

```sh
aws s3 cp lims-<version>-arm64.tar.gz s3://<releases_bucket>/                          # on your machine
aws s3 cp s3://<releases_bucket>/lims-<version>-arm64.tar.gz /srv/ && docker load -i /srv/lims-<version>-arm64.tar.gz   # on the server
```

Then add a company as [ONBOARDING.md](../../ONBOARDING.md) says, with two more lines in its `deployment.env`. The private half of the age key stays off the server:

```sh
BACKUP_AGE_RECIPIENT="age1..."
BACKUP_OFFSITE_CMD=...                                # terraform output -raw backup_command
```

Add its API host to `health_check_hosts` and apply again. Confirm the alarm emails' subscriptions.

## Getting back

| What happened | Do |
| --- | --- |
| The server is broken, the disk is fine | `terraform apply -replace=aws_instance.server` (see below). Same address, same data: Docker starts every company by itself and the nightly backups are put back |
| The data disk is lost or wrong | Find the snapshot (EC2 > Snapshots, name `lims-data`). `terraform state rm aws_ebs_volume.data`, set `data_snapshot_id`, plan, apply. The old disk stays until you delete it |
| The zone is down | As above, with `availability_zone` changed as well |
| The region is down | A server anywhere, and [Rebuilding on a new server](../../DEPLOYMENT.md#rebuilding-on-a-new-server) |

Replacing the server needs `disable_api_termination` turned off first: `aws ec2 modify-instance-attribute --instance-id <id> --no-disable-api-termination`.

A database in a snapshot is as after a power cut: PostgreSQL recovers it on start. Once a month, restore the latest off-site backup somewhere else and sign in.

## What cannot be undone

Off-site backups are locked for `backup_lock_days` from the moment they are written, for everyone, and are paid for until then. The backup bucket's Object Lock can only be set when it is made.
