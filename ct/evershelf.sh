#!/usr/bin/env bash
_CS_DEFAULT_URL="https://raw.githubusercontent.com/community-scripts/DevScripts/main"
_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../core}/core/build.func"
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/build.func")
# Copyright (c) 2021-2026 community-scripts ORG
# Author: maximedelvaux
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/dadaloop82/EverShelf

APP="EverShelf"
var_tags="${var_tags:-inventory;food}"
var_cpu="${var_cpu:-1}"
var_ram="${var_ram:-1024}"
var_disk="${var_disk:-4}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

# Remote access, read by install/evershelf-install.sh (prompted when empty):
# lan | tailscale | cloudflare | both
export var_evershelf_access="${var_evershelf_access:-}"
export var_tailscale_authkey="${var_tailscale_authkey:-}"
export var_cloudflared_token="${var_cloudflared_token:-}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -d /opt/evershelf ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  if check_for_gh_release "evershelf" "dadaloop82/EverShelf"; then
    msg_info "Stopping Services"
    systemctl stop cron apache2
    msg_ok "Stopped Services"

    msg_info "Snapshotting Database"
    if [[ -f /opt/evershelf/data/evershelf.db ]]; then
      mkdir -p /opt/evershelf/data/backups
      sqlite3 /opt/evershelf/data/evershelf.db ".backup '/opt/evershelf/data/backups/pre-update-$(date +%Y%m%d-%H%M%S).db'"
    fi
    msg_ok "Snapshotted Database"

    create_backup /opt/evershelf/data/mealie_pushed.json
    CLEAN_INSTALL=1 CLEAN_INSTALL_KEEP=".env data logs" fetch_and_deploy_gh_release "evershelf" "dadaloop82/EverShelf" "tarball"
    restore_backup
    PHP_VERSION="8.4" PHP_APACHE="YES" PHP_MODULE="sqlite3" setup_php

    msg_info "Updating ${APP}"
    $STD bash /opt/evershelf/scripts/install-transformers-model.sh
    for sapi in apache2 cli; do
      cp /opt/evershelf/docker/php-evershelf.ini "/etc/php/8.4/${sapi}/conf.d/99-evershelf.ini"
    done
    cp /opt/evershelf/docker/avahi-evershelf.xml /etc/avahi/services/evershelf.service
    sed 's|/var/www/html|/opt/evershelf|g' /opt/evershelf/docker/evershelf-cron >/etc/cron.d/evershelf
    chmod 0644 /etc/cron.d/evershelf
    mkdir -p /opt/evershelf/data/backups /opt/evershelf/logs
    chown -R www-data:www-data /opt/evershelf/data /opt/evershelf/logs /opt/evershelf/.env /opt/evershelf/assets/vendor/transformers
    chmod -R 775 /opt/evershelf/data
    chmod 640 /opt/evershelf/.env
    msg_ok "Updated ${APP}"

    msg_info "Starting Services"
    systemctl start apache2 cron
    msg_ok "Started Services"
    msg_ok "Updated successfully!"
  fi

  if command -v tailscale >/dev/null || command -v cloudflared >/dev/null; then
    msg_info "Updating Remote Access Agents"
    $STD apt update
    $STD apt install --only-upgrade -y tailscale cloudflared
    msg_ok "Updated Remote Access Agents"
  fi
  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Access it using the following URL:${CL}"
echo -e "${GATEWAY}${BGN}https://${IP}${CL}"
echo -e "${INFO}${YW}Self-signed certificate: accept the browser warning once (the camera needs HTTPS).${CL}"
