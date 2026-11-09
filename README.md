# EverShelf — Proxmox VE LXC script

A [community-scripts](https://community-scripts.org) style installer for
[EverShelf](https://github.com/dadaloop82/EverShelf), the self-hosted smart pantry
manager (inventory, barcode scanning, expiry tracking, shopping lists, AI recipes).

One command on the Proxmox host creates a Debian 13 unprivileged LXC container
with EverShelf ready to use: HTTPS, `evershelf.local`, and, if you want them,
remote access through **Tailscale** and/or a **Cloudflare Tunnel**.

> **Status:** written against the current community-scripts core and EverShelf
> v1.16.x. It has **not been tested on real Proxmox hardware yet**: reports
> are welcome in [issues](../../issues). Planned for submission to
> [community-scripts/DevScripts](https://github.com/community-scripts/DevScripts).

## Install

Run on the **Proxmox VE host** shell:

```bash
COMMUNITY_SCRIPTS_URL=https://raw.githubusercontent.com/maximedelvaux/proxmox-evershelf-script/main \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/maximedelvaux/proxmox-evershelf-script/main/ct/evershelf.sh)"
```

`COMMUNITY_SCRIPTS_URL` makes the loader fetch the in-container installer from
this repository. Once the script is merged upstream, you will no longer need it.

Then:

1. Pick the remote access mode when asked (default: LAN only).
2. Open `https://<container-ip>` or `https://evershelf.local`, and accept the
   self-signed certificate warning once.
3. The EverShelf setup wizard asks for the language and the AI provider key
   (Gemini, OpenAI or a local OpenAI-compatible model). Done.

Defaults: 1 vCPU, 1 GB RAM, 4 GB disk, Debian 13, unprivileged.

### Unattended install

Each prompt has a matching variable:

```bash
var_evershelf_access=both \
var_tailscale_authkey=tskey-auth-… \
var_cloudflared_token=eyJ… \
COMMUNITY_SCRIPTS_URL=https://raw.githubusercontent.com/maximedelvaux/proxmox-evershelf-script/main \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/maximedelvaux/proxmox-evershelf-script/main/ct/evershelf.sh)"
```

| Variable | Values | Default |
|---|---|---|
| `var_evershelf_access` | `lan`, `tailscale`, `cloudflare`, `both` | prompt (then `lan`) |
| `var_tailscale_authkey` | Tailscale auth key | prompt (empty: sign in with a link) |
| `var_cloudflared_token` | Cloudflare Tunnel token | prompt (empty: connect later) |

The usual community-scripts variables (`var_cpu`, `var_ram`, `var_disk`, …) work too.

## What gets installed

Same setup as the upstream `Dockerfile`, with paths moved from `/var/www/html` to
`/opt/evershelf`.

| Component | Details |
|---|---|
| Runtime | PHP 8.4 (Sury) + Apache `mod_php`, with `rewrite`, `headers`, `ssl` |
| App | Latest GitHub release (tarball) in `/opt/evershelf`. Installed version in `~/.evershelf` |
| Data | SQLite `/opt/evershelf/data/evershelf.db` (WAL), app backups in `data/backups/` |
| Config | `/opt/evershelf/.env` (from `.env.example`, editable from the in-app Settings) |
| HTTPS | Self-signed certificate in `/etc/ssl/evershelf/`. Browsers allow the camera (barcode/expiry scanning) only in a secure context |
| HTTP | Port 80 redirects direct clients to HTTPS. Reverse proxies (`X-Forwarded-Proto`) and local tunnels (`127.0.0.1`) are served as is |
| mDNS | `avahi-daemon` publishes `<hostname>.local` and `_evershelf._tcp`, which the EverShelf Android kiosk app uses for auto-discovery |
| Timezone | PHP `date.timezone` follows the container timezone |
| OCR | `tesseract-ocr` with the `eng` and `ita` packs (the languages the app hardcodes) |
| Offline model | MiniLM (~23 MB) for offline category classification |
| Cron | `/etc/cron.d/evershelf` runs `cron_smart_shopping.php` every 5 min (backups, caches, retention) |
| PHP tuning | Upstream `docker/php-evershelf.ini` (OPcache, 512M), for Apache and CLI |
| Helper | `evershelf-pairing-code` prints the one-time pairing code when `API_TOKEN` is set |

**Access control:** EverShelf has no user accounts, only an optional API token.
In `lan` and `tailscale` mode the app is open to whoever can reach it, as with the
official Docker image. Choosing `cloudflare` or `both` turns the token on (see below).

## Remote access

| | Tailscale | Cloudflare Tunnel |
|---|---|---|
| Who | Devices on your tailnet (private) | Anyone with the URL (public) |
| Client app needed | Tailscale | None |
| URL | `https://<hostname>.<tailnet>.ts.net` | `https://evershelf.your-domain.tld` |
| Certificate | Valid (Let's Encrypt via `tailscale serve`) | Valid (Cloudflare) |
| EverShelf auth | Unchanged (tailnet is private) | **`API_TOKEN` enabled**: each browser pairs once |
| Proxmox host changes | None (userspace networking, no `/dev/net/tun`) | None |

Both can run side by side (`both`). With a valid certificate the camera works, the
PWA can be installed, and no certificate warning appears.

### Tailscale

One-time setup: Tailscale admin console → **DNS** → enable **MagicDNS** and
**HTTPS Certificates**.

During install, paste an auth key (admin console → Settings → Keys), or press
Enter to sign in through the link that is printed (valid 5 min). The script then
runs `tailscale serve --bg https+insecure://127.0.0.1:443` and prints the URL.

Manual fallback, inside the container:

```bash
tailscale up
tailscale serve --bg https+insecure://127.0.0.1:443
```

### Cloudflare Tunnel

1. Cloudflare dashboard → **Zero Trust → Networks → Tunnels → Create a tunnel**
   (cloudflared), and copy the token (the long `eyJ…` string in the install command).
2. Add a **public hostname**, e.g. `evershelf.your-domain.tld`, with
   service **HTTP** → `127.0.0.1:80`.
3. Paste the token when the script asks (or later: `cloudflared service install <TOKEN>`).

The script sets a random `API_TOKEN` and `TRUSTED_PROXIES=127.0.0.1` in `.env`.
The token also applies on the LAN. To pair a browser:

```bash
evershelf-pairing-code   # inside the container: one-time code, valid 30 min
```

After the first device is paired, **Settings → System → Security** on that
device shows a fresh code, so you no longer need the container.

> **Security:** a Cloudflare Tunnel URL is public. Keep `API_TOKEN` set while
> the tunnel is up. For an extra layer, put **Cloudflare Access** in front
> (Zero Trust → Access → Applications, with an *email one-time PIN* policy
> limited to your users).

### Other reverse proxies (NPM, Caddy, Traefik)

Point the proxy to `http://<container-ip>:80`. These proxies send `X-Forwarded-Proto`
by default. In `.env`, set `TRUSTED_PROXIES=<proxy-ip>`, and also `API_TOKEN` if
the URL is public.

## mDNS (`evershelf.local`)

Hardening for LXC:

| LXC problem | Mitigation |
|---|---|
| `rlimit-nproc=3`: unprivileged containers share host UIDs, so avahi fails once a second container runs it | limit removed |
| `Type=dbus` unit: avahi does not start when D-Bus is missing or broken | drop-in `Type=simple` + `enable-dbus=warn` |
| Occasional crash | `Restart=on-failure` (5 s) |
| Clients receive an unusable IPv6 address | IPv4-only announcements |
| Name already taken on the LAN (avahi renames itself `evershelf-2.local`) | the name actually claimed is read back and printed |
| mDNS still fails | warning only: the install continues and the app stays reachable by IP |

Limits outside the container:

- mDNS does not cross VLANs or subnets. You need an mDNS reflector on the router.
- If the Proxmox firewall is enabled for the container, allow UDP 5353 to `224.0.0.251`.
- Some clients cannot resolve `.local` (older Android, some Windows or VPN setups).
  A DHCP reservation plus a local DNS record is the most reliable fallback.

Diagnostics: `systemctl status avahi-daemon` and
`journalctl -u avahi-daemon -b | grep -i "host name"`.

## Update

Run `update` inside the container (or run the install command again from the
container shell). The update:

1. compares the installed release with the latest one, and stops if they match;
2. stops Apache and cron, then snapshots the database to `data/backups/pre-update-*.db`;
3. reinstalls the app from scratch, keeping `.env`, `data/` and `logs/`
   (tracked files in `data/` are refreshed, `mealie_pushed.json` is preserved);
4. reapplies the offline model, PHP ini, mDNS service, cron and permissions, then restarts;
5. upgrades `tailscale` / `cloudflared` when they are installed.

The certificate, Apache vhost and timezone are left untouched.

## Testing locally

When `ct/` and `install/` sit side by side, the `build.func` loader uses the local
installer, so you can test without pushing:

```bash
scp -r ct install root@pve:/root/evershelf-script/
ssh root@pve 'bash /root/evershelf-script/ct/evershelf.sh'
```

Checklist:

- [ ] Install succeeds; `https://<ip>` opens after accepting the certificate
- [ ] `http://<ip>` redirects to HTTPS
- [ ] `https://evershelf.local` resolves from a LAN client, and the name is printed at the end of the install
- [ ] A second EverShelf container on the same host: avahi starts in both (`evershelf-2.local`)
- [ ] Wizard saves the language and AI key (`.env` written, www-data permissions OK)
- [ ] Camera barcode scan on a phone, product added
- [ ] `tail /opt/evershelf/data/cron.log` shows runs every 5 min
- [ ] Dates shown in the right timezone
- [ ] Forced update (`rm ~/.evershelf`, then `update`): data and `.env` intact
- [ ] After a container reboot, Apache, cron, avahi (and tailscaled / cloudflared) are running again
- [ ] Tailscale: `https://<hostname>.<tailnet>.ts.net` from a phone, valid certificate, camera scan works
- [ ] Cloudflare: public URL shows the pairing screen, and `evershelf-pairing-code` pairs the device
- [ ] Cloudflare: no redirect loop; rate limiting sees the real client IP (not 127.0.0.1)
- [ ] Unattended install with all three `var_*` variables

## Repository layout

```
ct/evershelf.sh                # Proxmox host: creates the container, holds update_script
install/evershelf-install.sh   # inside the container: installs and configures EverShelf
json/evershelf.json            # website metadata (entered through the community-scripts JSON generator)
```

## Submitting to community-scripts

New scripts go to **[DevScripts](https://github.com/community-scripts/DevScripts)**
(formerly ProxmoxVED), not ProxmoxVE.

1. Fork DevScripts, create a `feat/evershelf` branch, and copy `ct/` and `install/`.
2. Enter the metadata from `json/evershelf.json` in the
   [JSON generator](https://community-scripts.org/json-generator) and pick a
   **category** (left empty here).
3. Fill in the *AI Assistance* section of the PR template. These scripts were
   written with AI assistance (Claude): name the model and effort level there.
4. `var_arm64` is not declared on purpose: set it to `yes` only after an arm64 test.

## Credits

- [EverShelf](https://github.com/dadaloop82/EverShelf) by Stimpfl Daniel (@dadaloop82), MIT.
- [community-scripts](https://github.com/community-scripts) for the core framework, MIT.

Licensed under [MIT](LICENSE).
