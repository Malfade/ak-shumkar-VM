# Scanner Distribution ISO

This folder contains scripts to package `ak-shumkar-VM` as a distributable ISO.

## 1) Build ISO

From project root:

```bash
chmod +x packaging/build-distribution-iso.sh packaging/install-from-iso.sh
./packaging/build-distribution-iso.sh 3.5.0
```

Output:
- `dist/ak-shumkar-vm-3.5.0.iso`
- `dist/ak-shumkar-vm-3.5.0.iso.sha256`

If version argument is omitted, current date is used.

## 2) What goes inside ISO

- `ak-shumkar-VM/` (project files, excluding local build/cache/dev folders)
- `install.sh` (installer helper)
- `README.txt` (quick start and legal note)

## 3) Client-side installation

```bash
sudo mount -o loop ak-shumkar-vm-3.5.0.iso /mnt
sudo bash /mnt/install.sh
cd /opt/ak-shumkar-VM
./security/licensectl.sh install --license-file <license.json> --signature-file <license.sig>
./start.sh
```

## 4) Notes for commercial distribution

- Open-source license obligations still apply (GPL/AGPL components).
- Keep and ship source + license texts (`COPYING`, `license-details.md`) with your delivery.
- If needed, add your own EULA/warranty terms as a separate document without removing upstream licenses.
