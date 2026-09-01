#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="ReClip"
APP_DIR="/opt/reclip"
REPO_URL="https://github.com/averygan/reclip.git"

CONTAINER_NAME="reclip"
IMAGE_NAME="reclip:production"
PORT="8899"

CPU_LIMIT="1.8"
MEMORY_LIMIT="3g"
MEMORY_SWAP="4g"
PIDS_LIMIT="128"

MAX_CONCURRENT_DOWNLOADS="2"
DOWNLOAD_LIMIT_GB="70"
MIN_FREE_GB="10"
FILE_TTL_MINUTES="30"

BACKUP_DIR="/opt/reclip-backups"
LOG_FILE="/var/log/reclip-installer.log"

DOMAIN="${1:-}"
EMAIL="${2:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    printf '%b\n' "${GREEN}[ReClip]${NC} $*"
}

warn() {
    printf '%b\n' "${YELLOW}[WARN]${NC} $*"
}

die() {
    printf '%b\n' "${RED}[ERROR]${NC} $*"
    exit 1
}

trap 'die "Installation failed at line ${LINENO}. Check ${LOG_FILE}"' ERR

if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root: sudo bash install.sh DOMAIN"
fi

mkdir -p "$(dirname "${LOG_FILE}")"
touch "${LOG_FILE}"
exec > >(tee -a "${LOG_FILE}") 2>&1

if [[ -z "${DOMAIN}" ]]; then
    echo
    echo "ReClip Production Installer"
    echo
    echo "Usage:"
    echo "  sudo bash install.sh reclip.example.com"
    echo
    echo "With Let's Encrypt:"
    echo "  sudo bash install.sh reclip.example.com admin@example.com"
    echo
    exit 1
fi

if [[ ! "${DOMAIN}" =~ ^[A-Za-z0-9.-]+$ ]]; then
    die "Invalid domain: ${DOMAIN}"
fi

log "Domain: ${DOMAIN}"
log "Application directory: ${APP_DIR}"

if [[ ! -f /etc/os-release ]]; then
    die "Cannot detect operating system."
fi

source /etc/os-release

if [[ "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *"debian"* ]]; then
    warn "This installer is designed primarily for Ubuntu/Debian."
fi

log "Updating package index..."
apt-get update -y

log "Installing required packages..."

PACKAGES=(
    ca-certificates
    curl
    wget
    git
    gnupg
    lsb-release
    nginx
    cron
    jq
    openssl
    unzip
)

apt-get install -y "${PACKAGES[@]}"

if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker..."

    install -m 0755 -d /etc/apt/keyrings

    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg |
            gpg --dearmor -o /etc/apt/keyrings/docker.gpg

        chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    ARCH="$(dpkg --print-architecture)"

    if [[ -z "${VERSION_CODENAME:-}" ]]; then
        VERSION_CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
    fi

    cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable
EOF

    apt-get update -y

    DOCKER_PACKAGES=(
        docker-ce
        docker-ce-cli
        containerd.io
        docker-buildx-plugin
        docker-compose-plugin
    )

    apt-get install -y "${DOCKER_PACKAGES[@]}"
else
    log "Docker already installed."
fi

systemctl enable --now docker
systemctl enable --now nginx
systemctl enable --now cron

docker --version
docker compose version

mkdir -p "${BACKUP_DIR}"

if [[ -d "${APP_DIR}" ]]; then
    log "Existing ReClip installation detected."

    BACKUP_PATH="${BACKUP_DIR}/reclip-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "${BACKUP_PATH}"

    for file in \
        app.py \
        Dockerfile \
        docker-compose.yml \
        requirements.txt \
        docker-entrypoint.sh \
        reclip.sh
    do
        if [[ -f "${APP_DIR}/${file}" ]]; then
            cp -a "${APP_DIR}/${file}" "${BACKUP_PATH}/"
        fi
    done

    log "Backup created: ${BACKUP_PATH}"
else
    log "Cloning ReClip repository..."
    git clone "${REPO_URL}" "${APP_DIR}"
fi

cd "${APP_DIR}"

if [[ -d ".git" ]]; then
    log "Updating ReClip repository..."

    git fetch --all --prune || true

    if git diff --quiet && git diff --cached --quiet; then
        git pull --ff-only || warn "Repository update skipped."
    else
        warn "Local modifications detected. They will be preserved."
    fi
fi

mkdir -p "${APP_DIR}/downloads"
mkdir -p "${APP_DIR}/templates"
mkdir -p "${APP_DIR}/static"

if [[ ! -f "${APP_DIR}/requirements.txt" ]]; then
    cat > "${APP_DIR}/requirements.txt" <<'EOF'
flask
yt-dlp
EOF
fi

if [[ ! -f "${APP_DIR}/docker-entrypoint.sh" ]]; then
    cat > "${APP_DIR}/docker-entrypoint.sh" <<'EOF'
#!/usr/bin/env sh
set -eu

echo "Updating yt-dlp..."

python -m pip install --user --upgrade yt-dlp

exec "$@"
EOF

    chmod +x "${APP_DIR}/docker-entrypoint.sh"
fi

cat > "${APP_DIR}/Dockerfile" <<'EOF'
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV PIP_DISABLE_PIP_VERSION_CHECK=1

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ffmpeg \
        ca-certificates \
        curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .

RUN pip install --no-cache-dir \
    -r requirements.txt \
    gunicorn

COPY . .

RUN useradd -m -u 1000 reclip && \
    mkdir -p /app/downloads && \
    chown -R reclip:reclip /app

USER reclip

ENV PATH=/home/reclip/.local/bin:$PATH

EXPOSE 8899

ENTRYPOINT ["sh", "/app/docker-entrypoint.sh"]

CMD ["gunicorn", \
     "-b", "0.0.0.0:8899", \
     "-w", "1", \
     "--threads", "4", \
     "--timeout", "600", \
     "--access-logfile", "-", \
     "app:app"]
EOF

cat > "${APP_DIR}/docker-compose.yml" <<EOF
services:
  reclip:
    build: .
    image: ${IMAGE_NAME}
    container_name: ${CONTAINER_NAME}

    ports:
      - "127.0.0.1:${PORT}:8899"

    volumes:
      - reclip-downloads:/app/downloads

    restart: unless-stopped

    cpus: "${CPU_LIMIT}"
    mem_limit: ${MEMORY_LIMIT}
    memswap_limit: ${MEMORY_SWAP}
    pids_limit: ${PIDS_LIMIT}

    security_opt:
      - no-new-privileges:true

    init: true

volumes:
  reclip-downloads:
EOF

cat > "${APP_DIR}/.dockerignore" <<'EOF'
.git
.gitignore
__pycache__
*.pyc
*.pyo
*.pyd
.env
.env.*
downloads
*.backup
*.pre-production
*.log
EOF

if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    log "Removing existing ReClip container..."
    docker rm -f "${CONTAINER_NAME}" || true
fi

log "Building production Docker image..."

docker build \
    --pull \
    -t "${IMAGE_NAME}" \
    "${APP_DIR}"

log "Starting ReClip..."

cd "${APP_DIR}"

docker compose up -d --force-recreate

log "Waiting for ReClip health endpoint..."

READY=0

for _ in $(seq 1 40); do
    if curl -fsS \
        --max-time 3 \
        "http://127.0.0.1:${PORT}/health" \
        >/dev/null 2>&1
    then
        READY=1
        break
    fi

    sleep 2
done

if [[ "${READY}" != "1" ]]; then
    docker logs --tail 100 "${CONTAINER_NAME}" || true
    die "ReClip did not become ready."
fi

log "ReClip is healthy."

CF_CONF="/etc/nginx/conf.d/reclip-cloudflare.conf"
TMP_CF="$(mktemp)"

{
    echo "# ReClip Cloudflare configuration"
    echo "# Generated: $(date -u)"

    curl -fsSL https://www.cloudflare.com/ips-v4 |
        while read -r ip; do
            [[ -n "${ip}" ]] && echo "set_real_ip_from ${ip};"
        done

    curl -fsSL https://www.cloudflare.com/ips-v6 |
        while read -r ip; do
            [[ -n "${ip}" ]] && echo "set_real_ip_from ${ip};"
        done

    echo "real_ip_header CF-Connecting-IP;"
    echo "real_ip_recursive on;"
    echo
    echo 'limit_req_zone $binary_remote_addr zone=reclip_info:10m rate=10r/m;'
    echo 'limit_req_zone $binary_remote_addr zone=reclip_download:10m rate=3r/m;'
} > "${TMP_CF}"

mv "${TMP_CF}" "${CF_CONF}"

SSL_DIR="/etc/nginx/ssl"
SSL_CERT="${SSL_DIR}/${DOMAIN}.pem"
SSL_KEY="${SSL_DIR}/${DOMAIN}.key"

NGINX_SITE="/etc/nginx/sites-available/${DOMAIN}"
NGINX_ENABLED="/etc/nginx/sites-enabled/${DOMAIN}"

mkdir -p "${SSL_DIR}"
mkdir -p /var/www/html

HAS_SSL="false"

if [[ -f "${SSL_CERT}" && -f "${SSL_KEY}" ]]; then
    HAS_SSL="true"
fi

log "Configuring Nginx..."

if [[ "${HAS_SSL}" == "true" ]]; then

cat > "${NGINX_SITE}" <<EOF
server {
    listen 80;
    listen [::]:80;

    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;

    server_name ${DOMAIN};

    ssl_certificate ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};

    client_max_body_size 20M;

    location / {
        proxy_pass http://127.0.0.1:${PORT};

        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_connect_timeout 60s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
    }
}
EOF

else

cat > "${NGINX_SITE}" <<EOF
server {
    listen 80;
    listen [::]:80;

    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        proxy_pass http://127.0.0.1:${PORT};

        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_connect_timeout 60s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
    }
}
EOF

fi

ln -sfn "${NGINX_SITE}" "${NGINX_ENABLED}"

nginx -t
systemctl reload nginx

if [[ -n "${EMAIL}" && "${HAS_SSL}" == "false" ]]; then

    log "Installing Certbot..."

    apt-get install -y certbot python3-certbot-nginx

    nginx -t
    systemctl reload nginx

    if certbot --nginx \
        --non-interactive \
        --agree-tos \
        --redirect \
        --email "${EMAIL}" \
        -d "${DOMAIN}"
    then
        log "Let's Encrypt certificate installed."

        HAS_SSL="true"
    else
        warn "Let's Encrypt certificate request failed."
        warn "Make sure DNS points to this server."
    fi
fi

cat > /usr/local/bin/reclip-cleanup <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

CONTAINER="${CONTAINER_NAME}"

docker inspect "\${CONTAINER}" >/dev/null 2>&1 || exit 0

docker exec "\${CONTAINER}" python3 - <<'PY'
import os
import time
import shutil

DOWNLOAD_DIR = "/app/downloads"

MAX_BYTES = ${DOWNLOAD_LIMIT_GB} * 1024 * 1024 * 1024
MIN_FREE_BYTES = ${MIN_FREE_GB} * 1024 * 1024 * 1024
TTL_SECONDS = ${FILE_TTL_MINUTES} * 60

def get_files():
    result = []

    for root, dirs, names in os.walk(DOWNLOAD_DIR):
        for name in names:
            path = os.path.join(root, name)

            try:
                if os.path.isfile(path):
                    result.append((
                        path,
                        os.path.getsize(path),
                        os.path.getmtime(path)
                    ))
            except OSError:
                pass

    return result

files = get_files()
now = time.time()

for path, size, mtime in files:
    if now - mtime > TTL_SECONDS:
        try:
            os.remove(path)
        except OSError:
            pass

files = get_files()

total = sum(item[1] for item in files)

try:
    free = shutil.disk_usage(DOWNLOAD_DIR).free
except OSError:
    free = MIN_FREE_BYTES

if total > MAX_BYTES or free < MIN_FREE_BYTES:
    files.sort(key=lambda item: item[2])

    for path, size, _ in files:
        try:
            os.remove(path)
            total -= size
            free = shutil.disk_usage(DOWNLOAD_DIR).free

            if total <= MAX_BYTES and free >= MIN_FREE_BYTES:
                break
        except OSError:
            pass
PY
EOF

chmod +x /usr/local/bin/reclip-cleanup

cat > /etc/cron.d/reclip-cleanup <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

*/10 * * * * root /usr/local/bin/reclip-cleanup >/dev/null 2>&1
EOF

chmod 644 /etc/cron.d/reclip-cleanup

log "Running final health check..."

curl -fsS \
    --max-time 10 \
    "http://127.0.0.1:${PORT}/health"

echo

log "Docker configuration:"

docker inspect "${CONTAINER_NAME}" \
    --format 'Image={{.Config.Image}} Memory={{.HostConfig.Memory}} NanoCPUs={{.HostConfig.NanoCpus}} Pids={{.HostConfig.PidsLimit}}'

echo
log "Container status:"

docker ps --filter "name=${CONTAINER_NAME}"

echo
log "Disk status:"

df -h /

echo
echo "============================================================"
echo " ReClip Production Installation Complete"
echo "============================================================"
echo
echo "Domain:"
echo "  https://${DOMAIN}"
echo
echo "Application:"
echo "  ${APP_DIR}"
echo
echo "Container:"
echo "  ${CONTAINER_NAME}"
echo
echo "Resources:"
echo "  CPU:       ${CPU_LIMIT}"
echo "  RAM:       ${MEMORY_LIMIT}"
echo "  Swap max:  ${MEMORY_SWAP}"
echo "  PIDs:      ${PIDS_LIMIT}"
echo
echo "Downloads:"
echo "  Concurrent: ${MAX_CONCURRENT_DOWNLOADS}"
echo "  Max disk:   ${DOWNLOAD_LIMIT_GB} GB"
echo "  Min free:   ${MIN_FREE_GB} GB"
echo "  TTL:        ${FILE_TTL_MINUTES} minutes"
echo
echo "Health:"
echo "  https://${DOMAIN}/health"
echo
echo "Logs:"
echo "  docker logs -f ${CONTAINER_NAME}"
echo
echo "Stats:"
echo "  docker stats ${CONTAINER_NAME}"
echo
echo "Cleanup:"
echo "  /usr/local/bin/reclip-cleanup"
echo
echo "Installer log:"
echo "  ${LOG_FILE}"
echo
echo "============================================================"
