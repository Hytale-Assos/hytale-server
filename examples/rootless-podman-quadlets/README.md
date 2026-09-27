# Rootless Podman + Quadlets (Rocky Linux 10)

Runs the Hytale server as a systemd user service, without root, with the
container locked down (no capabilities, read-only rootfs, no privilege
escalation).

Image pipeline: `.github/workflows/ci.yml` builds the image (linux/amd64) and
publishes it to GitHub Packages as `ghcr.io/hytale-assos/hytale-server`.
The Quadlet pulls it from there; `podman auto-update` follows `:latest`.

The image contains **no Hytale files** (Hytale EULA §3.3). Hypixel's
downloader and the server are fetched into `~/hytale/data` at first start,
with your own Hytale account.

### Image tags

| Tag | Meaning |
|---|---|
| `:0.6.8` | Built for Hytale release 0.6.8 (rebuilt when our image changes) |
| `:latest` | Newest build, for the newest Hytale release |

CI checks Hypixel's public Maven metadata every 6 hours and publishes a new
tag when a Hytale release comes out (release channel only).

A tag says which release the image was **built for**, not which one runs: the
server is downloaded at runtime and keeps itself up to date (in-game updater).
The boot log shows both, and warns when they differ:

```
Hytale server version...           0.6.8
```

Target host: Rocky Linux 10 x86_64 (Podman 5.x, SELinux enforcing, firewalld,
cgroup v2). Any distro with Podman ≥ 5.0 works the same way.

## 1. Prepare the host (once)

```bash
sudo dnf install -y podman

# Keep user services running after logout and start them at boot
sudo loginctl enable-linger "$USER"

# Data directory + a private copy of the machine ID
mkdir -p ~/hytale/data
cp /etc/machine-id ~/hytale/machine-id

# Open the game port
sudo firewall-cmd --permanent --add-port=5520/udp && sudo firewall-cmd --reload

# Recommended for QUIC/UDP throughput
echo 'net.core.rmem_max=2097152' | sudo tee /etc/sysctl.d/90-hytale.conf
sudo sysctl --system
```

`PodmanArgs=--memory=8g` needs the memory cgroup controller delegated to user
sessions. Check with `cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/cgroup.controllers`:
`memory` must be listed. If not, remove that line or enable delegation.

### Access to the image

Packages published from the workflow start **private**. Either:

- make it public: GitHub → organization *Hytale-Assos* → Packages →
  `hytale-server` → Package settings → Change visibility → Public; or
- keep it private and log in once on the server with a personal access token
  (classic, scope `read:packages` only). Use the persistent auth file so
  `podman auto-update` still works after a reboot:

  ```bash
  podman login ghcr.io --authfile ~/.config/containers/auth.json
  ```

## 2. Install the units

```bash
mkdir -p ~/.config/containers/systemd
cp hytale.container hytale.env ~/.config/containers/systemd/
systemctl --user daemon-reload
```

Edit `hytale.env` (server name, timezone, …) and, in `hytale.container`, the
image tag and `--memory` limit.

### Secrets (optional)

Never put passwords or tokens in `hytale.env`:

```bash
printf '%s' 'my-server-password' | podman secret create hytale-password -
```

Then uncomment the matching `Secret=` line in `hytale.container`. Same pattern
for `HYTALE_SESSION_TOKEN` / `HYTALE_IDENTITY_TOKEN`.

## 3. First start and authentication

```bash
systemctl --user start hytale
journalctl --user -u hytale -f
```

The first boot prints a device-login URL for the downloader, downloads the
server files, then prints a second one for the server itself. Open each one, log in with
your Hytale account, and the server continues on its own. Credentials are
persisted encrypted in `~/hytale/data`, so later restarts need no login.

No TTY is needed: everything happens through the logs.

## Day-to-day

| Task | Command |
|---|---|
| Logs | `journalctl --user -u hytale -f` |
| Console command | `podman exec hytale hytale-cmd /op add <player>` |
| Stop (saves the world) | `systemctl --user stop hytale` |
| Restart | `systemctl --user restart hytale` |
| Status / health | `systemctl --user status hytale` · `podman healthcheck run hytale` |
| Update image now | `podman auto-update` (or wait for `podman-auto-update.timer`) |
| Check the units | `/usr/libexec/podman/quadlet -dryrun -user` |

`systemctl --user stop` sends `/stop` to the server console and waits up to
`StopTimeout` (90 s) for the world to be saved. A crash restarts the service;
a clean stop does not. The in-game `/update` command restarts the server in
place.

To enable scheduled image updates (daily by default):
`systemctl --user enable --now podman-auto-update.timer`. Every merge to
`main` then reaches the server automatically; a failed start rolls back to the
previous image.

## Backups

World backups (`HYTALE_BACKUP_*` in `hytale.env`) land in
`~/hytale/data/Server/backups`. They live on the same disk: copy that
directory elsewhere (restic, borg, rsync…) for real disaster recovery.

## Troubleshooting

- **Asked to log in again after recreating the container**: `~/hytale/machine-id`
  changed or is missing. Keep that file with your backups.
- **`Permission denied` on `~/hytale/data`**: files created by an older
  root/Docker setup. They must belong to your host user (it *is* uid 1000 in
  the container). Fix once with `podman unshare chown -R 0:0 ~/hytale/data`
  (uid 0 inside `podman unshare` is your own user), or `sudo chown -R "$USER": ~/hytale/data`.
- **A mod fails writing outside the data volume**: comment out `ReadOnly=true`.
