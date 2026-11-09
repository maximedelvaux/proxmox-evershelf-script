#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: maximedelvaux
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/dadaloop82/EverShelf

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt install -y \
  sqlite3 \
  cron \
  jq \
  avahi-daemon \
  tesseract-ocr \
  tesseract-ocr-eng \
  tesseract-ocr-ita
msg_ok "Installed Dependencies"

PHP_VERSION="8.4" PHP_APACHE="YES" PHP_MODULE="sqlite3" setup_php
fetch_and_deploy_gh_release "evershelf" "dadaloop82/EverShelf" "tarball"

msg_info "Downloading Offline Classification Model"
$STD bash /opt/evershelf/scripts/install-transformers-model.sh
msg_ok "Downloaded Offline Classification Model"

msg_info "Configuring EverShelf"
cd /opt/evershelf
cp .env.example .env
mkdir -p data/backups logs
chown -R www-data:www-data data logs .env
chmod -R 775 data
chmod 640 .env
TZ_NAME="$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')"
for sapi in apache2 cli; do
  cp docker/php-evershelf.ini "/etc/php/8.4/${sapi}/conf.d/99-evershelf.ini"
  echo "date.timezone = ${TZ_NAME:-UTC}" >"/etc/php/8.4/${sapi}/conf.d/99-evershelf-timezone.ini"
done
msg_ok "Configured EverShelf"

msg_info "Configuring Apache (HTTP + HTTPS)"
create_self_signed_cert "evershelf" "DNS:$(hostname).local"
cat <<EOF >/etc/apache2/sites-available/evershelf.conf
<Directory /opt/evershelf>
  Options -Indexes +FollowSymLinks
  AllowOverride All
  Require all granted
</Directory>

<VirtualHost *:80>
  DocumentRoot /opt/evershelf
  # Behind a TLS-terminating reverse proxy: treat forwarded HTTPS as on.
  SetEnvIf X-Forwarded-Proto "https" HTTPS=on
  # Direct LAN clients go to HTTPS: browsers only allow the camera (barcode and
  # expiry scanning) in a secure context. Reverse-proxied requests and local
  # tunnels (cloudflared on 127.0.0.1) stay on HTTP.
  RewriteEngine On
  RewriteCond %{HTTP:X-Forwarded-Proto} ^$
  RewriteCond %{REMOTE_ADDR} !^127\.0\.0\.1$
  RewriteRule ^ https://%{SERVER_NAME}%{REQUEST_URI} [R=302,L]
  ErrorLog \${APACHE_LOG_DIR}/error.log
  CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>

<VirtualHost *:443>
  DocumentRoot /opt/evershelf
  SSLEngine on
  SSLCertificateFile /etc/ssl/evershelf/evershelf.crt
  SSLCertificateKeyFile /etc/ssl/evershelf/evershelf.key
  ErrorLog \${APACHE_LOG_DIR}/error.log
  CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF
$STD a2enmod rewrite headers ssl
$STD a2dissite 000-default.conf
$STD a2ensite evershelf.conf
$STD systemctl restart apache2
msg_ok "Configured Apache (HTTP + HTTPS)"

msg_info "Configuring mDNS Discovery"
cp /opt/evershelf/docker/avahi-evershelf.xml /etc/avahi/services/evershelf.service
# - rlimit-nproc: unprivileged CTs share host UIDs, so avahi's 3-process cap
#   trips as soon as another container runs avahi too.
# - enable-dbus=warn: keep serving mDNS even if D-Bus is unavailable.
# - IPv4 only: clients always get a routable A record for <hostname>.local.
sed -i \
  -e 's/^#\?rlimit-nproc=.*/#rlimit-nproc=3/' \
  -e 's/^#\?enable-dbus=.*/enable-dbus=warn/' \
  -e 's/^#\?use-ipv6=.*/use-ipv6=no/' \
  -e 's/^#\?publish-aaaa-on-ipv4=.*/publish-aaaa-on-ipv4=no/' \
  /etc/avahi/avahi-daemon.conf
# Type=dbus ties the daemon's start to D-Bus; run it as a plain process that
# restarts itself instead.
mkdir -p /etc/systemd/system/avahi-daemon.service.d
cat <<EOF >/etc/systemd/system/avahi-daemon.service.d/override.conf
[Service]
Type=simple
Restart=on-failure
RestartSec=5
EOF
systemctl daemon-reload
systemctl enable -q avahi-daemon
MDNS_SINCE="$(date +%s)"
MDNS_NAME=""
if $STD systemctl restart avahi-daemon; then
  # The name is claimed only after probing the LAN, and avahi renames itself
  # (evershelf-2.local, ...) on a conflict: read back the name it really got.
  for _ in {1..15}; do
    MDNS_NAME="$(journalctl -u avahi-daemon --since "@${MDNS_SINCE}" -o cat --no-pager 2>/dev/null |
      sed -n 's/.*Host name is \([^ ]*\.local\)\..*/\1/p' | tail -1)"
    [[ -n "$MDNS_NAME" ]] && break
    sleep 1
  done
fi
if [[ -n "$MDNS_NAME" ]]; then
  msg_ok "Configured mDNS Discovery (https://${MDNS_NAME})"
else
  msg_warn "mDNS not confirmed: EverShelf stays reachable at https://${LOCAL_IP}"
fi

msg_info "Creating Cron Job"
sed 's|/var/www/html|/opt/evershelf|g' /opt/evershelf/docker/evershelf-cron >/etc/cron.d/evershelf
chmod 0644 /etc/cron.d/evershelf
systemctl enable -q --now cron
msg_ok "Created Cron Job"

cat <<'EOF' >/usr/local/bin/evershelf-pairing-code
#!/usr/bin/env bash
# Prints the one-time code that pairs a new browser when API_TOKEN is set.
if ! grep -q '^API_TOKEN=.' /opt/evershelf/.env; then
  echo "API_TOKEN is not set: no pairing needed."
  exit 0
fi
curl -fsk -o /dev/null "https://127.0.0.1/api/index.php?action=app_bootstrap" || true
code="$(jq -r '.code // empty' /opt/evershelf/data/api_pairing.json 2>/dev/null)"
echo "${code:-No code yet: open EverShelf in a browser, then run this again.}"
EOF
chmod +x /usr/local/bin/evershelf-pairing-code

ACCESS="${var_evershelf_access:-}"
if [[ -z "$ACCESS" ]]; then
  case "$(prompt_select "Remote access to EverShelf:" 1 60 \
    "LAN only" \
    "Tailscale (private: your devices only)" \
    "Cloudflare Tunnel (public URL)" \
    "Tailscale + Cloudflare Tunnel")" in
  "Tailscale ("*) ACCESS="tailscale" ;;
  "Cloudflare"*) ACCESS="cloudflare" ;;
  "Tailscale +"*) ACCESS="both" ;;
  *) ACCESS="lan" ;;
  esac
fi

if [[ "$ACCESS" == "tailscale" || "$ACCESS" == "both" ]]; then
  msg_info "Installing Tailscale"
  setup_deb822_repo "tailscale" \
    "https://pkgs.tailscale.com/stable/debian/$(get_os_info codename).noarmor.gpg" \
    "https://pkgs.tailscale.com/stable/debian" \
    "$(get_os_info codename)" \
    "main"
  $STD apt install -y tailscale
  # Userspace networking needs no /dev/net/tun: nothing to change on the Proxmox host.
  if grep -q '^FLAGS=' /etc/default/tailscaled; then
    sed -i 's|^FLAGS=.*|FLAGS="--tun=userspace-networking"|' /etc/default/tailscaled
  else
    echo 'FLAGS="--tun=userspace-networking"' >>/etc/default/tailscaled
  fi
  systemctl enable -q tailscaled
  $STD systemctl restart tailscaled
  msg_ok "Installed Tailscale"

  TS_KEY="${var_tailscale_authkey:-}"
  if [[ -z "$TS_KEY" ]]; then
    TS_KEY="$(prompt_password "Tailscale auth key (Enter = sign in with a link instead)" "" 120)"
  fi
  if [[ -n "$TS_KEY" ]]; then
    $STD tailscale up --auth-key="$TS_KEY" --hostname="$(hostname)" --timeout=60s || true
  elif ! is_unattended && [[ -t 0 ]]; then
    echo -e "${INFO}${YW}Open the link below to add EverShelf to your tailnet (waits 5 min):${CL}"
    tailscale up --hostname="$(hostname)" --timeout=5m || true
  fi
  if tailscale status >/dev/null 2>&1; then
    # tailscale serve gives a real Let's Encrypt certificate on <host>.<tailnet>.ts.net.
    if timeout 30 tailscale serve --bg https+insecure://127.0.0.1:443 </dev/null >/dev/null 2>&1; then
      TS_HOST="$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')"
      msg_ok "Tailscale ready: https://${TS_HOST}"
    else
      msg_warn "Enable HTTPS certificates in the Tailscale admin console (DNS page), then run: tailscale serve --bg https+insecure://127.0.0.1:443"
    fi
  else
    msg_warn "Tailscale not signed in. Run: tailscale up && tailscale serve --bg https+insecure://127.0.0.1:443"
  fi
fi

if [[ "$ACCESS" == "cloudflare" || "$ACCESS" == "both" ]]; then
  msg_info "Installing Cloudflared"
  setup_deb822_repo "cloudflared" \
    "https://pkg.cloudflare.com/cloudflare-main.gpg" \
    "https://pkg.cloudflare.com/cloudflared/" \
    "any" \
    "main"
  $STD apt install -y cloudflared
  msg_ok "Installed Cloudflared"

  msg_info "Securing EverShelf for public access"
  # A public URL must not be an open door: require the API token (each new
  # browser pairs once) and trust cloudflared's X-Forwarded-For for rate limits.
  sed -i \
    -e "s|^API_TOKEN=.*|API_TOKEN=$(openssl rand -hex 32)|" \
    -e "s|^TRUSTED_PROXIES=.*|TRUSTED_PROXIES=127.0.0.1|" \
    /opt/evershelf/.env
  msg_ok "Secured EverShelf for public access (pairing code: evershelf-pairing-code)"

  CF_TOKEN="${var_cloudflared_token:-}"
  if [[ -z "$CF_TOKEN" ]]; then
    CF_TOKEN="$(prompt_password "Cloudflare Tunnel token (Enter = connect later)" "" 120)"
  fi
  if [[ -n "$CF_TOKEN" ]] && $STD cloudflared service install "$CF_TOKEN"; then
    msg_ok "Connected Cloudflare Tunnel (public hostname service: http://127.0.0.1:80)"
  else
    msg_warn "Cloudflare Tunnel not connected. Run: cloudflared service install <TOKEN>"
  fi
fi

motd_ssh
customize
cleanup_lxc
