#!/usr/bin/env bash

set -Eeuo pipefail

APP_NAME="reclip"
APP_DIR="/opt/reclip"

APP_REPO="https://github.com/averygan/reclip.git"

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

mkdir -p "$(dirname "${LOG_FILE}")"

exec > >(tee -a "${LOG_FILE}") 2>&1

log "=============================================="
log "ReClip Production Installer"
log "=============================================="
log "Domain: ${DOMAIN}"
log "Application directory: ${APP_DIR}"

if [[ ! -f /etc/os-release ]]; then
    die "Cannot detect operating system."
fi

source /etc/os-release

if [[ "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *"debian"* ]]; then
    warn "This installer is designed for Ubuntu/Debian."
fi

export DEBIAN_FRONTEND=noninteractive

log "Updating package index..."

apt-get update -y

log "Installing required packages..."

APT_PACKAGES=(
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

apt-get install -y "${APT_PACKAGES[@]}"

log "Required packages installed."

if ! command -v docker >/dev/null 2>&1; then

    log "Docker is not installed."
    log "Installing Docker..."

    install -d -m 0755 /etc/apt/keyrings

    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then

        curl -fsSL \
            https://download.docker.com/linux/ubuntu/gpg \
            | gpg --dearmor \
            > /etc/apt/keyrings/docker.gpg

        chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    ARCH="$(dpkg --print-architecture)"
    CODENAME="${VERSION_CODENAME:-}"

    if [[ -z "${CODENAME}" ]]; then
        CODENAME="$(lsb_release -cs)"
    fi

    cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable
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

if ! docker compose version >/dev/null 2>&1; then
    die "Docker Compose plugin is not available."
fi

docker --version
docker compose version

systemctl enable --now nginx
systemctl enable --now cron

mkdir -p "${BACKUP_DIR}"

if [[ -d "${APP_DIR}" ]]; then

    log "Existing ReClip installation detected."

    BACKUP_PATH="${BACKUP_DIR}/reclip-$(date +%Y%m%d-%H%M%S)"

    mkdir -p "${BACKUP_PATH}"

    BACKUP_FILES=(
        app.py
        Dockerfile
        docker-compose.yml
        requirements.txt
        docker-entrypoint.sh
        reclip.sh
    )

    for file in "${BACKUP_FILES[@]}"; do
        if [[ -f "${APP_DIR}/${file}" ]]; then
            cp -a "${APP_DIR}/${file}" "${BACKUP_PATH}/"
        fi
    done

    log "Backup created: ${BACKUP_PATH}"

else

    log "Cloning ReClip application..."

    git clone "${APP_REPO}" "${APP_DIR}"

fi

cd "${APP_DIR}"

if [[ -d ".git" ]]; then

    log "Updating ReClip repository..."

    git fetch --all --prune || true

    if git diff --quiet && git diff --cached --quiet; then
        git pull --ff-only || true
    else
        warn "Local modifications detected."
        warn "Keeping local files."
    fi

fi

mkdir -p "${APP_DIR}/downloads"

chown -R root:root "${APP_DIR}"

if [[ ! -f "${APP_DIR}/requirements.txt" ]]; then

    cat > "${APP_DIR}/requirements.txt" <<'EOF'
flask
yt-dlp
EOF

fi

if [[ ! -f "${APP_DIR}/Dockerfile" ]]; then

    log "Creating Dockerfile..."

    cat > "${APP_DIR}/Dockerfile" <<'EOF'
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV PIP_DISABLE_PIP_VERSION_CHECK=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ffmpeg \
       ca-certificates \
       curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt gunicorn

COPY . .

RUN useradd -m -u 1000 reclip \
    && mkdir -p /app/downloads \
    && chown -R reclip:reclip /app

USER reclip

ENV PATH=/home/reclip/.local/bin:$PATH

EXPOSE 8899

ENTRYPOINT ["sh", "/app/docker-entrypoint.sh"]

CMD ["gunicorn", "-b", "0.0.0.0:8899", "-w", "1", "--threads", "4", "--timeout", "600", "--access-logfile", "-", "app:app"]
EOF

fi

if [[ ! -f "${APP_DIR}/docker-entrypoint.sh" ]]; then

    log "Creating docker-entrypoint.sh..."

    cat > "${APP_DIR}/docker-entrypoint.sh" <<'EOF'
#!/bin/sh

set -eu

echo "Starting ReClip..."

if command -v yt-dlp >/dev/null 2>&1; then
    echo "Updating yt-dlp..."
    python -m pip install --user --upgrade yt-dlp >/dev/null 2>&1 || true
fi

exec "$@"
EOF

    chmod +x "${APP_DIR}/docker-entrypoint.sh"

fi

cat > "${APP_DIR/.dockerignore}" <<'EOF'
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
