# Adding a new laboratory

Each laboratory gets its own installation: its own containers, database and file storage, on a cloud VM or on a server at the lab. Allow about 30 minutes once the server is set up (see [DEPLOYMENT.md](DEPLOYMENT.md)).

You set only server settings. Everything about the lab itself (name, legal details, GSTIN, bank account, NABL details, logo, colours, tests) is entered by the lab's administrator in the app, in a setup wizard after the first sign-in. Those changes apply at once, need no redeploy, and upgrades never overwrite them.

## 1. Collect

- The product name to show before the lab sets its own (`BRAND_NAME`), usually your product's name
- Domains: `app.`, `api.` and `files.` under one domain (cloud), or names on the lab's network (on-premise)
- SMTP details for outgoing email: host, port, user, password, sender address

The lab's administrator will need, in the wizard: legal and trading names, addresses, GSTIN and PAN, bank details for invoices, NABL certificate number and ULR format if accredited, logo, and colours. Send them that list in advance.

## 2. Make their folder, outside this repository

```sh
SLUG=acme
mkdir -p /srv/lims-clients/$SLUG
cd /opt/lims-deploy/clients/_template
cp deployment.env.example /srv/lims-clients/$SLUG/deployment.env
cp versions.env.example   /srv/lims-clients/$SLUG/versions.env
```

Fill in both files. Double-quote every value. `S3_IMAGE` must be the storage image your organisation has chosen; see [DECISIONS.md](DECISIONS.md). There is no `company.env` for a new laboratory.

## 3. Point DNS

- **Cloud:** create records for the three domains pointing at the server. TLS certificates need them to resolve.
- **On-premise (LAN):** add the three names to the lab's DNS server or to each computer's hosts file, pointing at the server's address. Use the lab's own certificates, or an internal CA trusted by its computers; browsers need HTTPS for the camera and phone-upload features. The server needs outbound internet only for email (and, optionally, PIN code auto-fill and error tracking); everything else runs offline.

## 4. Provision

```sh
/opt/lims-deploy/scripts/provision.sh --client-dir /srv/lims-clients/$SLUG
```

This generates the secrets, starts the containers, runs the database migrations and installs the nightly backup. Before real data goes in, set backup encryption and an off-site copy in `deployment.env` (`BACKUP_AGE_RECIPIENT`, `BACKUP_OFFSITE_CMD`, `BACKUP_PING_URL`; see [DEPLOYMENT.md](DEPLOYMENT.md#backups)), then run `scripts/backup.sh --client-dir /srv/lims-clients/$SLUG` once and check it ends without `BACKUP FAILED`.

Store a copy of `secrets.env` in your secrets store. If the folder is lost, the app cannot reach its own database and storage until those passwords are reset by hand.

## 5. First administrator

Open `https://<app domain>`. The first-run screen asks for the `SETUP_TOKEN` from `secrets.env`, then creates the first administrator and the lab's operating settings (GST rate, credit days, working days, retention, terms). Give the administrator their sign-in.

## 6. The lab's setup wizard

When the administrator signs in, the app opens **Set up your laboratory**:

1. **Lab profile**: names, addresses, GSTIN (fills state and PAN), bank account, accreditation and NABL mode, document number prefix, support and legal links
2. **Branding**: app name, colours (with ready palettes and a live preview), sign-in line, "Powered by", logo, browser icon, sign-in picture
3. **Lab type**: optional starting test catalogues built from public standards: water and wastewater (IS 10500, effluent limits), ambient air and stack, soil, noise, materials and metals. Tests, parameters, methods, limits and packages; no prices, nothing marked accredited
4. **Team**: add users and roles in Admin → Users
5. **Email**: send a test email to confirm SMTP works
6. **Review** and finish

Anything skipped can be done later; until setup is finished, administrators see a reminder.

## 7. Hand over

As that administrator:

1. Add prices (Masters → Standard rates) and mark accredited tests and methods from the lab's NABL scope.
2. Add the lab's own tests, instruments and specifications, or import them from Excel.
3. Book one job through to an issued report and an invoice, and check the PDFs and emails with the lab.

## Demo data

For a trial only, add `--with-demo-data` to `provision.sh`. A demo install skips the setup wizard. Before going live, remove the demo data with:

```sh
/opt/lims-deploy/scripts/remove-demo.sh --client-dir /srv/lims-clients/$SLUG --yes
```

This removes demo users, customers, masters and everything recorded against them. The audit log keeps its history, since it is append-only.

## Laboratories installed before the admin panel

Older installs keep their `company.env` and `branding/` folder. On the first start of a version with the admin panel, those are checked and imported into the app once (logo and favicon included), and the setup wizard is skipped. From then on the app is the place to change them; the files can stay as a record but are no longer read.
