# Trial and small installations

Everything on one machine, at one address, started with one command. For trials, evaluations, proofs of concept and small laboratories. For several companies on one server, with TLS certificates and scheduled backups, use `../compose` and `../scripts` ([DEPLOYMENT.md](../DEPLOYMENT.md)).

## Needs

- Docker Engine or Docker Desktop with Compose 2.24 or later
- About 4 GB of memory and 10 GB of disk free
- The images: sign in to the registry (`docker login ghcr.io`), or load the files you were sent (`docker load -i <file>`)

## Start

```sh
cp .env.example .env      # fill in the versions and the licence
docker compose up -d --wait
```

Then read the one-time setup token and open the address in `LIMS_URL` (http://localhost:8080 unless you changed it):

```sh
docker compose exec api cat /run/lims/setup-token
```

The first screen asks for that token and creates the first administrator. The setup wizard follows. The token stops working once an administrator exists.

Passwords and keys are made on first start and kept in the `secrets` volume. They are never printed and never in `.env`.

## Opening it from other computers and phones

The app answers at one address only, because emails, QR codes and file links carry it. By default that is this machine.

1. Choose a name the other machines can resolve, and set `LIMS_URL` to it, with the port.
2. Set `LIMS_BIND=0.0.0.0`, then `docker compose up -d`.
3. Put HTTPS in front (your own proxy), set `LIMS_URL=https://…` and `COOKIE_SECURE=true`. Over plain HTTP, passwords cross the network readable, and browsers refuse the camera, scanning and installing the app anywhere but on `localhost`. Your proxy must replace `X-Forwarded-For` and pass the Host header on.

## The trial

- It counts from the first start with the licence, and also ends on the licence's last day, whichever comes first.
- Administrators are told 14, 7, 3 and 1 days before it ends, and everyone sees a banner.
- **When it ends nothing is deleted.** Everything stays readable, and PDFs and exports still work. Nothing new can be saved.
- To extend it or buy, send the installation number shown in **Admin → Licence**, and paste the licence you get back there. Work carries on at once.

## Everyday

| To | Run |
| --- | --- |
| See that all is well | `docker compose ps` |
| Read the logs | `docker compose logs -f api worker` |
| Stop, keeping everything | `docker compose down` |
| Back up | `./backup.sh` |
| Restore | `./restore.sh backups/<time> --yes` |
| Upgrade | `./backup.sh`, change the versions in `.env`, `docker compose up -d --wait` |
| Let in an administrator who lost their two-factor phone | `docker compose exec api sh /lims/with-secrets.sh node dist/recover.js reset-2fa <email>` |

`docker compose down -v` **deletes all data**.

A backup holds customer data and this installation's secrets: keep it as carefully as the installation, and keep a copy on another machine. To move to another machine, copy this folder and the backup there and run `restore.sh`.

Migrations only go forward. To go back to an earlier version, put the old versions in `.env` and restore the backup made before the upgrade; anything entered since is lost.

## What the licence can and cannot prevent

The licence is checked without calling anyone, so it works offline. It is signed, so it cannot be altered; the check is in the server, so changing the browser does nothing; and setting the clock back gives no time back. A person who controls the machine can still replace the program or the database. Wiping the volumes starts again, with nothing in it, and only until the licence's last day.
