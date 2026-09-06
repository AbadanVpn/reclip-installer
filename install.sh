#!/usr/bin/env bash

set -Eeuo pipefail

APP_NAME="reclip"
APP_DIR="/opt/reclip"
REPO_URL="https://github.com/averygan/reclip.git"

CONTAINER_NAME="reclip"
IMAGE_NAME="reclip:production"
PORT="8899"

CPU_LIMIT="1.8"
MEMORY_LIMIT="3g"
MEMORY_SWAP="4g"
PIDS_LIMIT="128"

DOWNLOAD_LIMIT_GB="70"
MIN_FREE_GB="10"
FILE_TTL_MINUTES="30"
MAX_CONCURRENT_DOWNLOADS="2"

BACKUP_DIR="/opt/reclip-backups"
LOG_FILE="/var/log/reclip-installer.log"

DOMAIN="${1:-}"
EMAIL="${2:-}"

NGINX_SITE="/etc/nginx/sites-available/${DOMAIN}"
NGINX_ENABLED="/etc/nginx/sites-enabled/${DOMAIN}"

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

mkdir -p "$(dirname "${LOG_FILE}")"
touch "${LOG_FILE}"

exec > >(tee -a "${LOG_FILE}") 2>&1

if [[ "${EUID}" -ne 0 ]]; then
die "Run as root: sudo bash install.sh DOMAIN"
fi

if [[ -z "${DOMAIN}" ]]; then
echo
echo "ReClip Production Installer"
echo
echo "Usage:"
echo "  sudo bash install.sh reclip.example.com"
echo
echo "With Let's Encrypt:"
echo "  sudo bash install.sh reclip.example.com [admin@example.com](mailto:admin@example.com)"
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

if [[ "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *debian* ]]; then
warn "This installer is designed primarily for Ubuntu/Debian."
fi

export DEBIAN_FRONTEND=noninteractive

log "Updating package index..."
apt-get update -y

log "Installing required packages..."

apt-get install -y ca-certificates curl wget git gnupg lsb-release nginx cron jq openssl unzip

systemctl enable --now nginx
systemctl enable --now cron

if ! command -v docker >/dev/null 2>&1; then

```
log "Docker is not installed. Installing Docker..."

install -m 0755 -d /etc/apt/keyrings

if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg |
        gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
fi

ARCH="$(dpkg --print-architecture)"

if [[ -r /etc/os-release ]]; then
    DOCKER_CODENAME="${VERSION_CODENAME:-}"
fi

if [[ -z "${DOCKER_CODENAME}" ]]; then
    DOCKER_CODENAME="$(lsb_release -cs)"
fi

printf '%s\n' \
    "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${DOCKER_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

apt-get update -y

apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

else

```
log "Docker already installed."

if ! docker compose version >/dev/null 2>&1; then
    log "Installing Docker Compose plugin..."
    apt-get update -y
    apt-get install -y docker-compose-plugin
fi
```

fi

systemctl enable --now docker

docker --version
docker compose version

mkdir -p "${BACKUP_DIR}"

if [[ -d "${APP_DIR}" && -f "${APP_DIR}/docker-compose.yml" ]]; then

```
BACKUP_PATH="${BACKUP_DIR}/reclip-$(date +%Y%m%d-%H%M%S)"

log "Existing ReClip installation detected."
log "Creating backup: ${BACKUP_PATH}"

mkdir -p "${BACKUP_PATH}"

cp -a "${APP_DIR}/docker-compose.yml" "${BACKUP_PATH}/" 2>/dev/null || true
cp -a "${APP_DIR}/Dockerfile" "${BACKUP_PATH}/" 2>/dev/null || true
cp -a "${APP_DIR}/requirements.txt" "${BACKUP_PATH}/" 2>/dev/null || true
cp -a "${APP_DIR}/app.py" "${BACKUP_PATH}/" 2>/dev/null || true
cp -a "${APP_DIR}/docker-entrypoint.sh" "${BACKUP_PATH}/" 2>/dev/null || true
```

else

```
if [[ -d "${APP_DIR}" && ! -d "${APP_DIR}/.git" ]]; then
    log "Existing directory found at ${APP_DIR}."
    log "Keeping existing files."
fi

if [[ ! -d "${APP_DIR}/.git" ]]; then

    if [[ -d "${APP_DIR}" ]]; then

        TEMP_REPO="$(mktemp -d)"

        log "Cloning ReClip repository into temporary directory..."

        git clone --depth 1 "${REPO_URL}" "${TEMP_REPO}/reclip"

        mkdir -p "${APP_DIR}"

        cp -a "${TEMP_REPO}/reclip/." "${APP_DIR}/"

        rm -rf "${TEMP_REPO}"

    else

        log "Cloning ReClip repository..."

        git clone "${REPO_URL}" "${APP_DIR}"

    fi

fi
```

fi

if [[ ! -d "${APP_DIR}" ]]; then
die "Application directory was not created: ${APP_DIR}"
fi

cd "${APP_DIR}"

if [[ ! -f "${APP_DIR}/app.py" ]]; then
die "app.py was not found in ${APP_DIR}"
fi

if [[ ! -f "${APP_DIR}/Dockerfile" ]]; then
die "Dockerfile was not found in ${APP_DIR}"
fi

if [[ ! -f "${APP_DIR}/docker-entrypoint.sh" ]]; then
die "docker-entrypoint.sh was not found in ${APP_DIR}"
fi

if [[ -d "${APP_DIR}/.git" ]]; then

```
log "Updating ReClip repository..."

git fetch --all --prune || true

if git diff --quiet && git diff --cached --quiet; then
    git pull --ff-only || warn "Could not fast-forward repository. Continuing with current files."
else
    warn "Local repository changes detected. They will be preserved."
fi
```

fi

chmod +x "${APP_DIR}/docker-entrypoint.sh" 2>/dev/null || true

log "Writing production docker-compose.yml..."

cat > "${APP_DIR}/docker-compose.yml" <<EOF
services:
reclip:
build:
context: .
dockerfile: Dockerfile

```
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
```

volumes:
reclip-downloads:
EOF

log "Writing Dockerfile..."

cat > "${APP_DIR}/Dockerfile" <<'EOF'
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV PIP_DISABLE_PIP_VERSION_CHECK=1

RUN apt-get update 
&& apt-get install -y --no-install-recommends ffmpeg ca-certificates curl 
&& rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt gunicorn

COPY . .

RUN useradd -m -u 1000 reclip 
&& mkdir -p /app/downloads 
&& chown -R reclip:reclip /app

USER reclip

ENV PATH=/home/reclip/.local/bin:$PATH

EXPOSE 8899

ENTRYPOINT ["sh", "/app/docker-entrypoint.sh"]

CMD ["gunicorn", "-b", "0.0.0.0:8899", "-w", "1", "--threads", "4", "--timeout", "600", "--access-logfile", "-", "app:app"]
EOF

log "Writing .dockerignore..."

cat > "${APP_DIR}/.dockerignore" <<'EOF'
.git
.gitignore
**pycache**
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

```
log "Removing existing container: ${CONTAINER_NAME}"

docker rm -f "${CONTAINER_NAME}" || true
```

fi

log "Building production Docker image..."

cd "${APP_DIR}"

docker build --pull -t "${IMAGE_NAME}" "${APP_DIR}"

log "Starting ReClip..."

docker compose up -d --force-recreate --remove-orphans

log "Waiting for ReClip health endpoint..."

READY=0

for i in $(seq 1 45); do

```
if curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    READY=1
    break
fi

sleep 2
```

done

if [[ "${READY}" != "1" ]]; then

```
warn "ReClip did not become ready."

docker ps -a --filter "name=${CONTAINER_NAME}" || true

docker logs --tail 150 "${CONTAINER_NAME}" || true

die "Health check failed."
```

fi

log "ReClip container is healthy."

CF_CONF="/etc/nginx/conf.d/reclip-cloudflare.conf"
TMP_CF="$(mktemp)"

log "Updating Cloudflare IP ranges..."

{
echo "# ReClip Cloudflare Real IP configuration"
echo "# Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo

```
curl -fsSL https://www.cloudflare.com/ips-v4 |
    while IFS= read -r ip; do
        [[ -n "${ip}" ]] && echo "set_real_ip_from ${ip};"
    done

curl -fsSL https://www.cloudflare.com/ips-v6 |
    while IFS= read -r ip; do
        [[ -n "${ip}" ]] && echo "set_real_ip_from ${ip};"
    done

echo
echo "real_ip_header CF-Connecting-IP;"
echo "real_ip_recursive on;"
echo
echo 'limit_req_zone $binary_remote_addr zone=reclip_info:10m rate=10r/m;'
echo 'limit_req_zone $binary_remote_addr zone=reclip_download:10m rate=3r/m;'
```

} > "${TMP_CF}"

mv "${TMP_CF}" "${CF_CONF}"

mkdir -p /var/www/html
mkdir -p /etc/nginx/sites-available
mkdir -p /etc/nginx/sites-enabled

SSL_CERT="/etc/nginx/ssl/${DOMAIN}.pem"
SSL_KEY="/etc/nginx/ssl/${DOMAIN}.key"

HAS_SSL="false"

if [[ -f "${SSL_CERT}" && -f "${SSL_KEY}" ]]; then
HAS_SSL="true"
log "Existing SSL certificate detected."
fi

log "Writing Nginx configuration..."

if [[ "${HAS_SSL}" == "true" ]]; then

cat > "${NGINX_SITE}" <<EOF
server {
listen 80;
listen [::]:80;

```
server_name ${DOMAIN};

location /.well-known/acme-challenge/ {
    root /var/www/html;
}

return 301 https://\$host\$request_uri;
```

}

server {
listen 443 ssl;
listen [::]:443 ssl;

```
server_name ${DOMAIN};

ssl_certificate ${SSL_CERT};
ssl_certificate_key ${SSL_KEY};

client_max_body_size 20M;

location = /health {
    proxy_pass http://127.0.0.1:${PORT};
    proxy_http_version 1.1;

    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    proxy_connect_timeout 10s;
    proxy_read_timeout 30s;
}

location = /api/info {
    limit_req zone=reclip_info burst=5 nodelay;

    proxy_pass http://127.0.0.1:${PORT};
    proxy_http_version 1.1;

    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    proxy_connect_timeout 10s;
    proxy_send_timeout 120s;
    proxy_read_timeout 120s;
}

location = /api/download {
    limit_req zone=reclip_download burst=2 nodelay;

    proxy_pass http://127.0.0.1:${PORT};
    proxy_http_version 1.1;

    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    proxy_connect_timeout 10s;
    proxy_send_timeout 120s;
    proxy_read_timeout 120s;
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
```

}
EOF

else

cat > "${NGINX_SITE}" <<EOF
server {
listen 80;
listen [::]:80;

```
server_name ${DOMAIN};

location /.well-known/acme-challenge/ {
    root /var/www/html;
}

location = /health {
    proxy_pass http://127.0.0.1:${PORT};
    proxy_http_version 1.1;

    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    proxy_connect_timeout 10s;
    proxy_read_timeout 30s;
}

location = /api/info {
    limit_req zone=reclip_info burst=5 nodelay;

    proxy_pass http://127.0.0.1:${PORT};
    proxy_http_version 1.1;

    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    proxy_connect_timeout 10s;
    proxy_send_timeout 120s;
    proxy_read_timeout 120s;
}

location = /api/download {
    limit_req zone=reclip_download burst=2 nodelay;

    proxy_pass http://127.0.0.1:${PORT};
    proxy_http_version 1.1;

    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    proxy_connect_timeout 10s;
    proxy_send_timeout 120s;
    proxy_read_timeout 120s;
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
```

}
EOF

fi

ln -sfn "${NGINX_SITE}" "${NGINX_ENABLED}"

if [[ -n "${EMAIL}" && "${HAS_SSL}" == "false" ]]; then

```
log "Installing Certbot..."

apt-get install -y certbot python3-certbot-nginx

nginx -t
systemctl reload nginx

if certbot --nginx \
    --non-interactive \
    --agree-tos \
    --redirect \
    --email "${EMAIL}" \
    -d "${DOMAIN}"; then

    log "Let's Encrypt certificate installed."

else

    warn "Let's Encrypt certificate installation failed."
    warn "Check DNS and Cloudflare SSL configuration."

fi
```

fi

log "Testing Nginx configuration..."

nginx -t

systemctl reload nginx

log "Installing ReClip cleanup command..."

cat > /usr/local/bin/reclip-cleanup <<EOF
#!/usr/bin/env bash

set -Eeuo pipefail

CONTAINER="${CONTAINER_NAME}"

if ! docker inspect "${CONTAINER}" >/dev/null 2>&1; then
exit 0
fi

docker exec "${CONTAINER}" python3 - <<'PYEOF'
import os
import time
import shutil

DOWNLOAD_DIR = "/app/downloads"

MAX_BYTES = ${DOWNLOAD_LIMIT_GB} * 1024 * 1024 * 1024
MIN_FREE_BYTES = ${MIN_FREE_GB} * 1024 * 1024 * 1024
TTL_SECONDS = ${FILE_TTL_MINUTES} * 60

files = []

for root, dirs, names in os.walk(DOWNLOAD_DIR):
for name in names:
path = os.path.join(root, name)

```
    try:
        if os.path.isfile(path):
            files.append(
                (
                    path,
                    os.path.getsize(path),
                    os.path.getmtime(path)
                )
            )
    except OSError:
        pass
```

now = time.time()

for path, size, mtime in files:
if now - mtime > TTL_SECONDS:
try:
os.remove(path)
except OSError:
pass

files = []

for root, dirs, names in os.walk(DOWNLOAD_DIR):
for name in names:
path = os.path.join(root, name)

```
    try:
        if os.path.isfile(path):
            files.append(
                (
                    path,
                    os.path.getsize(path),
                    os.path.getmtime(path)
                )
            )
    except OSError:
        pass
```

total = sum(item[1] for item in files)

try:
free = shutil.disk_usage(DOWNLOAD_DIR).free
except OSError:
free = MIN_FREE_BYTES

if total > MAX_BYTES or free < MIN_FREE_BYTES:

```
files.sort(key=lambda item: item[2])

for path, size, mtime in files:

    try:
        os.remove(path)

        total -= size

        free = shutil.disk_usage(DOWNLOAD_DIR).free

        if total <= MAX_BYTES and free >= MIN_FREE_BYTES:
            break

    except OSError:
        pass
```

PYEOF
EOF

chmod 0755 /usr/local/bin/reclip-cleanup

cat > /etc/cron.d/reclip-cleanup <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

*/10 * * * * root /usr/local/bin/reclip-cleanup >/dev/null 2>&1
EOF

chmod 0644 /etc/cron.d/reclip-cleanup

systemctl enable --now cron

log "Running local health check..."

curl -fsS --max-time 10 "[http://127.0.0.1:${PORT}/health](http://127.0.0.1:${PORT}/health)"

echo

log "Docker configuration:"

docker inspect "${CONTAINER_NAME}" 
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
echo "Image:"
echo "  ${IMAGE_NAME}"
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
echo "Rate limits:"
echo "  /api/info:     10 requests/minute"
echo "  /api/download: 3 requests/minute"
echo
echo "Health:"
echo "  /health"
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
echo
log "Installation finished successfully."
