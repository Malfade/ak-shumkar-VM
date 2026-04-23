# Production License and Access Hardening

This repository now includes a baseline production flow for:

1. Time-bound licenses (3/6/12 months) that block scanner startup after expiry.
2. Host hardening for "one admin account + one service account" operation model.

## 1) License workflow

Use `scannerctl.sh` wrapper:

```bash
./scannerctl.sh license-vendor gen-keys
./scannerctl.sh license-vendor issue --customer-id acme --months 6
sudo ./scannerctl.sh license install \
  --license-file ./vendor/licensing/output/license-acme-6m.json \
  --signature-file ./vendor/licensing/output/license-acme-6m.json.sig
./scannerctl.sh license status
```

What happens:

- `vendor/licensing/license-vendorctl.sh issue` creates a canonical JSON license.
- JSON is signed with RSA private key (`vendor/licensing/output/private.pem`).
- `start.sh` verifies signature + `expires_at` at startup.
- If expired or invalid, startup is blocked.

Environment overrides:

- `ALLOW_EXPIRED_LICENSE=1` — bypass check (emergency only).
- `LICENSE_INSTALL_DIR`, `LICENSE_FILE`, `LICENSE_SIG_FILE`, `LICENSE_PUBLIC_KEY` — custom paths.

## 2) One-account access hardening

Run as root:

```bash
sudo ./scannerctl.sh harden --admin-user <your-linux-admin-user>
```

What it applies:

- Creates service account `scanner` (no login shell).
- Restricts project permissions to service/admin groups.
- Updates `sshd_config` to allow only selected admin user.
- Disables root SSH and password auth (`PermitRootLogin no`, `PasswordAuthentication no`).

## 3) Security notes

- Keep `vendor/licensing/output/private.pem` off production hosts.
- Store private signing key in a separate secure system.
- Root access cannot be fully removed in Linux.
- Runtime check is in `start.sh` (blocks stack startup); deeper GMP-level enforcement can be added later.
