```bash
#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# ReClip Uninstaller
# ============================================================
#
# Normal:
#   sudo bash uninstall.sh
#
# Remove EVERYTHING including downloads:
#   sudo bash uninstall.sh --purge
#
# ============================================================

APP_DIR="/opt/reclip"
CONTAINER_NAME="reclip"
VOLUME_NAME="reclip-downloads"

DOMAIN="${1:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    printf '%b\n' "${GREEN}[ReClip]${NC} $*"
}

warn() {
    printf '%b\n' "${YELLOW}[WARN]${NC} $*"
}

die() {
    printf '%b\n' "${RED}[ERROR]${NC} $*" >&2
    exit 1
}

if [[ "$EUID" -ne 0 ]]; then
    die "Run as root: sudo bash uninstall.sh"
fi

PURGE="false"

if [[ "${1:-}" == "--purge" ]]; then
    PURGE="true"
    DOMAIN="${2:-}"
fi

echo
echo "============================================================"
echo " ReClip Uninstaller"
echo "============================================================"
echo

if [[ "${PURGE}" == "true" ]]; then

    warn "PURGE mode enabled."
    warn "The ReClip downloads Docker volume will be deleted."
    echo

    read -r -p "Type REMOVE to continue: " CONFIRM

    if [[ "${CONFIRM}" != "REMOVE" ]]; then
        echo "Cancelled."
        exit 0
    fi
fi

# ============================================================
# Detect domain
# ============================================================

if [[ -z "${DOMAIN}" && -d /etc/nginx/sites-enabled ]]; then

    DOMAIN="$(find /etc/nginx/sites-enabled \
        -maxdepth 1 \
        -type l \
        -name '*.netcheck.info' \
        -printf '%f\n' \
        | head -n 1 || true)"

fi

# ============================================================
# Container
# ============================================================

if docker ps -a \
    --format '{{.Names}}' \
    | grep -qx "${CONTAINER_NAME}"; then

    log "Removing ReClip container..."

    docker rm -f "${CONTAINER_NAME}" || true

fi

# ============================================================
# Compose
# ============================================================

if [[ -f "${APP_DIR}/docker-compose.yml" ]]; then

    cd "${APP_DIR}"

    docker compose down \
        --remove-orphans \
        || true

fi

# ============================================================
# Image
# ============================================================

if docker image inspect reclip:production >/dev/null 2>&1; then
    log "Removing ReClip production image..."
    docker image rm -f reclip:production || true
fi

if docker image inspect reclip:latest >/dev/null 2>&1; then
    log "Removing ReClip latest image..."
    docker image rm -f reclip:latest || true
fi

# ============================================================
# Volume
# ============================================================

if [[ "${PURGE}" == "true" ]]; then

    if docker volume inspect "${VOLUME_NAME}" >/dev/null 2>&1; then
        log "Removing downloads volume..."
        docker volume rm "${VOLUME_NAME}" || true
    fi

else

    log "Downloads volume preserved."
    log "Use --purge if you want to remove it."

fi

# ============================================================
# Cleanup command
# ============================================================

if [[ -f /usr/local/bin/reclip-cleanup ]]; then
    log "Removing cleanup command..."
    rm -f /usr/local/bin/reclip-cleanup
fi

# ============================================================
# Cron
# ============================================================

if [[ -f /etc/cron.d/reclip-cleanup ]]; then
    log "Removing cleanup cron..."
    rm -f /etc/cron.d/reclip-cleanup
fi

# ============================================================
# Nginx
# ============================================================

if [[ -n "${DOMAIN}" ]]; then

    NGINX_SITE="/etc/nginx/sites-available/${DOMAIN}"
    NGINX_ENABLED="/etc/nginx/sites-enabled/${DOMAIN}"

    if [[ -L "${NGINX_ENABLED}" || -f "${NGINX_ENABLED}" ]]; then
        log "Removing Nginx site..."
        rm -f "${NGINX_ENABLED}"
    fi

    if [[ -f "${NGINX_SITE}" ]]; then
        rm -f "${NGINX_SITE}"
    fi

fi

# Remove Cloudflare config created by ReClip.

if [[ -f /etc/nginx/conf.d/reclip-cloudflare.conf ]]; then
    log "Removing ReClip Cloudflare Nginx configuration..."
    rm -f /etc/nginx/conf.d/reclip-cloudflare.conf
fi

if command -v nginx >/dev/null 2>&1; then

    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx
    else
        warn "Nginx configuration test failed. Nginx was not reloaded."
    fi

fi

# ============================================================
# Application directory
# ============================================================

if [[ -d "${APP_DIR}" ]]; then
    log "Removing application directory..."
    rm -rf "${APP_DIR}"
fi

# ============================================================
# Final
# ============================================================

echo

if [[ "${PURGE}" == "true" ]]; then
    log "ReClip has been completely removed."
else
    log "ReClip application has been removed."
    log "Downloads volume was preserved."
fi

echo

echo "============================================================"
echo " ReClip Uninstall Complete"
echo "============================================================"
echo
echo "Docker:"
docker ps -a --filter "name=reclip" || true
echo
echo "Remaining ReClip volumes:"
docker volume ls | grep reclip || true
echo
echo "Backups:"
echo "  /opt/reclip-backups"
echo
```
