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
    printf '%b\n' "${YELLOW}[WARN]${NC} $*" >&2
}

die() {
    printf '%b\n' "${RED}[ERROR]${NC} $*" >&2
    exit 1
}

trap 'die "Installation failed at line $LINENO. Check ${LOG_FILE}"' ERR

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

echo
echo "============================================================"
echo " ReClip Production Installer"
echo "============================================================"
echo

if [[ "$EUID" -ne 0 ]]; then
    die "Run as root: sudo bash install.sh DOMAIN"
fi

if [[ -z "$DOMAIN" ]]; then
    echo "Usage:"
    echo
    echo "  sudo bash install.sh reclip.example.com"
    echo
    echo "With Let's Encrypt:"
    echo
    echo "  sudo bash install.sh reclip.example.com admin@example.com"
    echo
    exit 1
fi

if [[ ! "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]]; then
    die "Invalid domain: $DOMAIN"
fi

if [[ ! "$DOMAIN" =~ \. ]]; then
    die "Domain must contain a valid hostname."
fi

log "Domain: ${DOMAIN}"
log "Application directory: ${APP_DIR}"

# ============================================================
# OS
# ============================================================

if [[ ! -f /etc/os-release ]]; then
    die "Cannot detect operating system."
fi

source /etc/os-release

if [[ "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *"debian"* ]]; then
    warn "This installer is designed for Ubuntu/Debian."
fi

# ============================================================
# Packages
# ============================================================

log "Updating package index..."

apt-get update -y

log "Installing required packages..."

apt-get install -y \
    ca-certificates \
    curl \
    wget \
    git \
    gnupg \
    lsb-release \
    nginx \
    cron \
    jq \
    openssl \
    unzip

# ============================================================
# Docker
# ============================================================

if ! command -v docker >/dev/null 2>&1; then

    log "Docker is not installed. Installing Docker..."

    install -m 0755 -d /etc/apt/keyrings

    if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
        curl -fsSL \
            https://download.docker.com/linux/ubuntu/gpg \
            -o /etc/apt/keyrings/docker.asc
    fi

    chmod a+r /etc/apt/keyrings/docker.asc

    ARCH="$(dpkg --print-architecture)"

    . /etc/os-release

    CODENAME="${VERSION_CODENAME:-}"

    if [[ -z "$CODENAME" ]]; then
        CODENAME="$(lsb_release -cs)"
    fi

    cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable
EOF

    apt-get update -y

    if ! apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin; then

        warn "Docker CE repository installation failed."
        warn "Trying Ubuntu Docker packages..."

        apt-get install -y \
            docker.io \
            docker-compose-v2
    fi

else

    log "Docker already installed."

fi

systemctl enable --now docker

if ! docker info >/dev/null 2>&1; then
    die "Docker daemon is not available."
fi

docker --version

if docker compose version >/dev/null 2>&1; then
    docker compose version
else
    die "Docker Compose plugin is not available."
fi

# ============================================================
# Nginx
# ============================================================

systemctl enable --now nginx

# ============================================================
# Backup existing installation
# ============================================================

mkdir -p "$BACKUP_DIR"

if [[ -d "$APP_DIR" ]]; then

    log "Existing ReClip installation detected."

    BACKUP_PATH="${BACKUP_DIR}/reclip-$(date +%Y%m%d-%H%M%S)"

    mkdir -p "$BACKUP_PATH"

    for FILE in \
        app.py \
        Dockerfile \
        docker-compose.yml \
        requirements.txt \
        docker-entrypoint.sh \
        reclip.sh \
        templates/index.html
    do

        if [[ -f "$APP_DIR/$FILE" ]]; then

            mkdir -p "$BACKUP_PATH/$(dirname "$FILE")"

            cp "$APP_DIR/$FILE" \
                "$BACKUP_PATH/$FILE"

        fi

    done

    log "Backup created: ${BACKUP_PATH}"

else

    log "Creating application directory..."

    mkdir -p "$APP_DIR"

fi

cd "$APP_DIR"

# ============================================================
# Clone repository only when application directory is empty
# ============================================================

if [[ ! -f "$APP_DIR/templates/index.html" ]]; then

    if [[ ! -d "$APP_DIR/.git" ]]; then

        log "Application source not found."
        log "Cloning ReClip repository..."

        TMP_REPO="$(mktemp -d)"

        if git clone "$REPO_URL" "$TMP_REPO/reclip"; then

            cp -a "$TMP_REPO/reclip/." "$APP_DIR/"

        else

            rm -rf "$TMP_REPO"

            die "Could not clone ReClip repository: ${REPO_URL}"

        fi

        rm -rf "$TMP_REPO"

    else

        log "Git repository already exists."

        git fetch --all --prune || true

        if git diff --quiet && git diff --cached --quiet; then
            git pull --ff-only || true
        else
            warn "Local modifications detected. They will be preserved."
        fi

    fi

fi

# ============================================================
# Verify frontend
# ============================================================

if [[ ! -f "$APP_DIR/templates/index.html" ]]; then
    die "templates/index.html was not found."
fi

# ============================================================
# Requirements
# ============================================================

log "Writing requirements.txt..."

cat > "$APP_DIR/requirements.txt" <<'EOF'
flask
yt-dlp
EOF

# ============================================================
# Production application
# ============================================================

log "Writing production app.py..."

cat > "$APP_DIR/app.py" <<'PYEOF'
import os
import uuid
import glob
import json
import time
import shutil
import subprocess
from concurrent.futures import ThreadPoolExecutor

from flask import Flask, request, jsonify, send_file, render_template


app = Flask(__name__)

DOWNLOAD_DIR = os.path.join(
    os.path.dirname(__file__),
    "downloads"
)

os.makedirs(DOWNLOAD_DIR, exist_ok=True)


# ============================================================
# Configuration
# ============================================================

MAX_CONCURRENT_DOWNLOADS = 2
DOWNLOAD_TIMEOUT = 300

DOWNLOAD_LIMIT_GB = 70
MIN_FREE_GB = 10
FILE_TTL_MINUTES = 30

MAX_DOWNLOADS_BYTES = (
    DOWNLOAD_LIMIT_GB
    * 1024
    * 1024
    * 1024
)

MIN_FREE_BYTES = (
    MIN_FREE_GB
    * 1024
    * 1024
    * 1024
)


# ============================================================
# Global state
# ============================================================

jobs = {}

download_executor = ThreadPoolExecutor(
    max_workers=MAX_CONCURRENT_DOWNLOADS,
    thread_name_prefix="reclip-download"
)


# ============================================================
# Helpers
# ============================================================

def parse_ytdlp_json(stdout):
    for line in stdout.splitlines():

        line = line.strip()

        if not line:
            continue

        return json.loads(line)

    raise ValueError("yt-dlp returned no data")


def safe_filename(title, fallback):

    if not title:
        return fallback

    safe = "".join(
        c for c in title
        if c not in r'\/:*?"<>|'
    )

    safe = safe.strip()[:100].strip()

    return safe or fallback


def cleanup_downloads():

    try:

        now = time.time()
        files = []

        for path in glob.glob(
            os.path.join(DOWNLOAD_DIR, "*")
        ):

            try:

                if not os.path.isfile(path):
                    continue

                files.append(
                    (
                        path,
                        os.path.getsize(path),
                        os.path.getmtime(path)
                    )
                )

            except OSError:
                pass

        # ----------------------------------------------------
        # TTL cleanup
        # ----------------------------------------------------

        for path, size, mtime in files:

            if now - mtime > FILE_TTL_MINUTES * 60:

                try:
                    os.remove(path)
                except OSError:
                    pass

        # ----------------------------------------------------
        # Recalculate
        # ----------------------------------------------------

        files = []

        for path in glob.glob(
            os.path.join(DOWNLOAD_DIR, "*")
        ):

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

        total_size = sum(
            item[1]
            for item in files
        )

        try:

            free_bytes = shutil.disk_usage(
                DOWNLOAD_DIR
            ).free

        except OSError:

            free_bytes = MIN_FREE_BYTES

        # ----------------------------------------------------
        # Enforce limits
        # ----------------------------------------------------

        if (
            total_size > MAX_DOWNLOADS_BYTES
            or free_bytes < MIN_FREE_BYTES
        ):

            files.sort(
                key=lambda item: item[2]
            )

            for path, size, _ in files:

                try:

                    os.remove(path)

                    total_size -= size

                    free_bytes = shutil.disk_usage(
                        DOWNLOAD_DIR
                    ).free

                    if (
                        total_size <= MAX_DOWNLOADS_BYTES
                        and free_bytes >= MIN_FREE_BYTES
                    ):
                        break

                except OSError:
                    pass

    except Exception:
        pass


# ============================================================
# Download worker
# ============================================================

def run_download(
    job_id,
    url,
    format_choice,
    format_id
):

    job = jobs.get(job_id)

    if not job:
        return

    job["status"] = "downloading"
    job["error"] = None

    cleanup_downloads()

    out_template = os.path.join(
        DOWNLOAD_DIR,
        f"{job_id}.%(ext)s"
    )

    cmd = [
        "yt-dlp",
        "--no-playlist",
        "--newline",
        "-o",
        out_template
    ]

    if format_choice == "audio":

        cmd += [
            "-x",
            "--audio-format",
            "mp3"
        ]

    elif format_id:

        cmd += [
            "-f",
            f"{format_id}+bestaudio/best",
            "--merge-output-format",
            "mp4"
        ]

    else:

        cmd += [
            "-f",
            "bestvideo+bestaudio/best",
            "--merge-output-format",
            "mp4"
        ]

    cmd.append(url)

    try:

        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=DOWNLOAD_TIMEOUT
        )

        if result.returncode != 0:

            job["status"] = "error"

            lines = (
                result.stderr.strip().splitlines()
            )

            job["error"] = (
                lines[-1]
                if lines
                else "yt-dlp failed"
            )

            return

        files = glob.glob(
            os.path.join(
                DOWNLOAD_DIR,
                f"{job_id}.*"
            )
        )

        if not files:

            job["status"] = "error"
            job["error"] = (
                "Download completed but no file was found"
            )

            return

        if format_choice == "audio":

            target = [
                f
                for f in files
                if f.endswith(".mp3")
            ]

        else:

            target = [
                f
                for f in files
                if f.endswith(".mp4")
            ]

        chosen = (
            target[0]
            if target
            else files[0]
        )

        for path in files:

            if path != chosen:

                try:
                    os.remove(path)
                except OSError:
                    pass

        job["status"] = "done"
        job["file"] = chosen

        ext = os.path.splitext(chosen)[1]

        title = job.get(
            "title",
            ""
        ).strip()

        base_filename = safe_filename(
            title,
            os.path.basename(chosen)
        )

        if title:

            if not base_filename.endswith(ext):
                base_filename += ext

        job["filename"] = base_filename

    except subprocess.TimeoutExpired:

        job["status"] = "error"

        job["error"] = (
            "Download timed out (5 min limit)"
        )

        for path in glob.glob(
            os.path.join(
                DOWNLOAD_DIR,
                f"{job_id}.*"
            )
        ):

            try:
                os.remove(path)
            except OSError:
                pass

    except Exception as exc:

        job["status"] = "error"
        job["error"] = str(exc)

    finally:

        cleanup_downloads()


# ============================================================
# Routes
# ============================================================

@app.route("/")
def index():

    return render_template(
        "index.html"
    )


@app.route("/health")
def health():

    return jsonify({
        "status": "ok",
        "service": "reclip",
        "max_concurrent_downloads":
            MAX_CONCURRENT_DOWNLOADS
    })


@app.route(
    "/api/info",
    methods=["POST"]
)
def get_info():

    data = request.get_json(
        silent=True
    ) or {}

    url = data.get(
        "url",
        ""
    ).strip()

    if not url:

        return jsonify({
            "error": "No URL provided"
        }), 400

    cmd = [
        "yt-dlp",
        "--no-playlist",
        "-j",
        url
    ]

    try:

        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=60
        )

        if result.returncode != 0:

            lines = (
                result.stderr.strip().splitlines()
            )

            return jsonify({
                "error": (
                    lines[-1]
                    if lines
                    else "yt-dlp failed"
                )
            }), 400

        info = parse_ytdlp_json(
            result.stdout
        )

        best_by_height = {}

        for fmt in info.get(
            "formats",
            []
        ):

            height = fmt.get(
                "height"
            )

            if (
                height
                and fmt.get(
                    "vcodec",
                    "none"
                ) != "none"
            ):

                tbr = (
                    fmt.get("tbr")
                    or 0
                )

                if (
                    height not in best_by_height
                    or tbr >
                    (
                        best_by_height[
                            height
                        ].get("tbr")
                        or 0
                    )
                ):

                    best_by_height[
                        height
                    ] = fmt

        formats = []

        for height, fmt in (
            best_by_height.items()
        ):

            formats.append({
                "id": fmt["format_id"],
                "label": f"{height}p",
                "height": height
            })

        formats.sort(
            key=lambda item:
                item["height"],
            reverse=True
        )

        return jsonify({
            "title": info.get(
                "title",
                ""
            ),
            "thumbnail": info.get(
                "thumbnail",
                ""
            ),
            "duration": info.get(
                "duration"
            ),
            "uploader": info.get(
                "uploader",
                ""
            ),
            "formats": formats
        })

    except subprocess.TimeoutExpired:

        return jsonify({
            "error":
                "Timed out fetching video info"
        }), 400

    except Exception as exc:

        return jsonify({
            "error": str(exc)
        }), 400


@app.route(
    "/api/playlist",
    methods=["POST"]
)
def get_playlist_info():

    data = request.get_json(
        silent=True
    ) or {}

    url = data.get(
        "url",
        ""
    ).strip()

    if not url:

        return jsonify({
            "error": "No URL provided"
        }), 400

    cmd = [
        "yt-dlp",
        "--flat-playlist",
        "-J",
        url
    ]

    try:

        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=60
        )

        if result.returncode != 0:

            lines = (
                result.stderr.strip().splitlines()
            )

            return jsonify({
                "error": (
                    lines[-1]
                    if lines
                    else "yt-dlp failed"
                )
            }), 400

        info = json.loads(
            result.stdout
        )

        entries = info.get(
            "entries",
            []
        )

        urls = [
            entry.get("url")
            for entry in entries
            if entry.get("url")
        ]

        return jsonify({
            "urls": urls
        })

    except subprocess.TimeoutExpired:

        return jsonify({
            "error":
                "Timed out fetching playlist info"
        }), 400

    except Exception as exc:

        return jsonify({
            "error": str(exc)
        }), 400


@app.route(
    "/api/download",
    methods=["POST"]
)
def start_download():

    data = request.get_json(
        silent=True
    ) or {}

    url = data.get(
        "url",
        ""
    ).strip()

    format_choice = data.get(
        "format",
        "video"
    )

    format_id = data.get(
        "format_id"
    )

    title = data.get(
        "title",
        ""
    )

    if not url:

        return jsonify({
            "error": "No URL provided"
        }), 400

    cleanup_downloads()

    job_id = uuid.uuid4().hex[:10]

    jobs[job_id] = {
        "status": "queued",
        "url": url,
        "title": title,
        "error": None
    }

    download_executor.submit(
        run_download,
        job_id,
        url,
        format_choice,
        format_id
    )

    return jsonify({
        "job_id": job_id,
        "status": "queued"
    })


@app.route(
    "/api/status/<job_id>"
)
def check_status(job_id):

    job = jobs.get(
        job_id
    )

    if not job:

        return jsonify({
            "error": "Job not found"
        }), 404

    return jsonify({
        "status": job.get(
            "status"
        ),
        "error": job.get(
            "error"
        ),
        "filename": job.get(
            "filename"
        )
    })


@app.route(
    "/api/file/<job_id>"
)
def download_file(job_id):

    job = jobs.get(
        job_id
    )

    if (
        not job
        or job.get("status") != "done"
        or not job.get("file")
    ):

        return jsonify({
            "error": "File not ready"
        }), 404

    path = job["file"]

    if not os.path.isfile(path):

        job["status"] = "error"
        job["error"] = (
            "File has been removed"
        )

        return jsonify({
            "error": "File no longer exists"
        }), 404

    return send_file(
        path,
        as_attachment=True,
        download_name=job.get(
            "filename",
            os.path.basename(path)
        )
    )


if __name__ == "__main__":

    port = int(
        os.environ.get(
            "PORT",
            8899
        )
    )

    host = os.environ.get(
        "HOST",
        "127.0.0.1"
    )

    app.run(
        host=host,
        port=port
    )
PYEOF

# ============================================================
# Dockerfile
# ============================================================

log "Writing Dockerfile..."

cat > "$APP_DIR/Dockerfile" <<'EOF'
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

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

# ============================================================
# Docker entrypoint
# ============================================================

if [[ ! -f "$APP_DIR/docker-entrypoint.sh" ]]; then

    log "Creating docker-entrypoint.sh..."

    cat > "$APP_DIR/docker-entrypoint.sh" <<'EOF'
#!/usr/bin/env sh
set -eu

echo "Updating yt-dlp..."

python -m pip install \
    --user \
    --upgrade \
    yt-dlp \
    >/dev/null 2>&1 || true

exec "$@"
EOF

    chmod +x "$APP_DIR/docker-entrypoint.sh"

fi

# ============================================================
# Docker Compose
# ============================================================

log "Writing docker-compose.yml..."

cat > "$APP_DIR/docker-compose.yml" <<EOF
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

# ============================================================
# Docker ignore
# ============================================================

cat > "$APP_DIR/.dockerignore" <<'EOF'
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

# ============================================================
# Remove existing container
# ============================================================

if docker ps -a \
    --format '{{.Names}}' \
    | grep -qx "$CONTAINER_NAME"; then

    log "Removing existing ReClip container..."

    docker rm -f "$CONTAINER_NAME" || true

fi

# ============================================================
# Build image
# ============================================================

log "Building production Docker image..."

docker build \
    --pull \
    -t "$IMAGE_NAME" \
    "$APP_DIR"

# ============================================================
# Start
# ============================================================

log "Starting ReClip..."

cd "$APP_DIR"

docker compose up -d \
    --force-recreate \
    --remove-orphans

# ============================================================
# Wait for container
# ============================================================

log "Waiting for ReClip container..."

for i in {1..40}; do

    if docker inspect \
        "$CONTAINER_NAME" \
        >/dev/null 2>&1; then

        RUNNING="$(docker inspect \
            -f '{{.State.Running}}' \
            "$CONTAINER_NAME" 2>/dev/null || echo false)"

        if [[ "$RUNNING" == "true" ]]; then
            break
        fi

    fi

    sleep 2

done

if ! docker inspect \
    "$CONTAINER_NAME" \
    >/dev/null 2>&1; then

    docker compose logs \
        --tail 100 || true

    die "ReClip container was not created."
fi

if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME")" != "true" ]]; then

    docker compose logs \
        --tail 100 || true

    die "ReClip container is not running."
fi

# ============================================================
# Health check
# ============================================================

log "Running local health check..."

READY=0

for i in {1..40}; do

    if curl -fsS \
        --max-time 5 \
        "http://127.0.0.1:${PORT}/health" \
        >/dev/null 2>&1; then

        READY=1
        break

    fi

    sleep 2

done

if [[ "$READY" != "1" ]]; then

    docker logs \
        --tail 100 \
        "$CONTAINER_NAME" || true

    die "ReClip did not become healthy."
fi

log "ReClip is healthy."

# ============================================================
# Cloudflare Nginx configuration
# ============================================================

log "Configuring Cloudflare real IP..."

CF_CONF="/etc/nginx/conf.d/reclip-cloudflare.conf"
TMP_CF="$(mktemp)"

{
    echo "# ReClip Cloudflare configuration"
    echo "# Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo

    curl -fsSL \
        https://www.cloudflare.com/ips-v4 \
        | while read -r ip; do

            [[ -n "$ip" ]] && \
                echo "set_real_ip_from ${ip};"

        done

    curl -fsSL \
        https://www.cloudflare.com/ips-v6 \
        | while read -r ip; do

            [[ -n "$ip" ]] && \
                echo "set_real_ip_from ${ip};"

        done

    echo
    echo "real_ip_header CF-Connecting-IP;"
    echo "real_ip_recursive on;"
    echo

    echo 'limit_req_zone $binary_remote_addr zone=reclip_info:10m rate=10r/m;'
    echo 'limit_req_zone $binary_remote_addr zone=reclip_download:10m rate=3r/m;'

} > "$TMP_CF"

mv "$TMP_CF" "$CF_CONF"

# ============================================================
# SSL
# ============================================================

SSL_CERT="/etc/nginx/ssl/${DOMAIN}.pem"
SSL_KEY="/etc/nginx/ssl/${DOMAIN}.key"

HAS_SSL="false"

if [[ -f "$SSL_CERT" && -f "$SSL_KEY" ]]; then
    HAS_SSL="true"
fi

if [[ "$HAS_SSL" == "true" ]]; then
    log "Existing SSL certificate detected."
else
    log "No existing SSL certificate detected."
fi

# ============================================================
# Nginx paths
# ============================================================

NGINX_SITE="/etc/nginx/sites-available/${DOMAIN}"
NGINX_ENABLED="/etc/nginx/sites-enabled/${DOMAIN}"

mkdir -p /var/www/html
mkdir -p /etc/nginx/sites-available
mkdir -p /etc/nginx/sites-enabled

# ============================================================
# Nginx HTTP configuration
# ============================================================

log "Writing Nginx configuration..."

if [[ "$HAS_SSL" == "true" ]]; then

    cat > "$NGINX_SITE" <<EOF
server {

    listen 80;
    listen [::]:80;

    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {

    listen 443 ssl;
    listen [::]:443 ssl;

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
}
EOF

else

    cat > "$NGINX_SITE" <<EOF
server {

    listen 80;
    listen [::]:80;

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
}
EOF

fi

ln -sfn \
    "$NGINX_SITE" \
    "$NGINX_ENABLED"

# ============================================================
# Optional Let's Encrypt
# ============================================================

if [[ -n "$EMAIL" && "$HAS_SSL" == "false" ]]; then

    log "Installing Certbot..."

    apt-get install -y \
        certbot \
        python3-certbot-nginx

    nginx -t

    systemctl reload nginx

    if certbot \
        --nginx \
        --non-interactive \
        --agree-tos \
        --redirect \
        --email "$EMAIL" \
        -d "$DOMAIN"; then

        log "Let's Encrypt certificate installed."

    else

        warn "Let's Encrypt certificate request failed."
        warn "Verify DNS and Cloudflare configuration."

    fi

fi

# ============================================================
# Nginx verification
# ============================================================

log "Testing Nginx..."

nginx -t

systemctl reload nginx

# ============================================================
# Cleanup script
# ============================================================

log "Installing cleanup command..."

cat > /usr/local/bin/reclip-cleanup <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

CONTAINER="${CONTAINER_NAME}"

if ! docker inspect "\$CONTAINER" >/dev/null 2>&1; then
    exit 0
fi

docker exec "\$CONTAINER" python3 - <<'PY'
import os
import time
import shutil

DOWNLOAD_DIR = "/app/downloads"

MAX_BYTES = ${DOWNLOAD_LIMIT_GB} * 1024 * 1024 * 1024
MIN_FREE_BYTES = ${MIN_FREE_GB} * 1024 * 1024 * 1024
TTL_SECONDS = ${FILE_TTL_MINUTES} * 60


def collect():
    result = []

    for root, dirs, names in os.walk(DOWNLOAD_DIR):

        for name in names:

            path = os.path.join(
                root,
                name
            )

            try:

                if os.path.isfile(path):

                    result.append(
                        (
                            path,
                            os.path.getsize(path),
                            os.path.getmtime(path)
                        )
                    )

            except OSError:
                pass

    return result


files = collect()
now = time.time()

for path, size, mtime in files:

    if now - mtime > TTL_SECONDS:

        try:
            os.remove(path)
        except OSError:
            pass


files = collect()

total = sum(
    item[1]
    for item in files
)

try:
    free = shutil.disk_usage(
        DOWNLOAD_DIR
    ).free
except OSError:
    free = MIN_FREE_BYTES


if (
    total > MAX_BYTES
    or free < MIN_FREE_BYTES
):

    files.sort(
        key=lambda item: item[2]
    )

    for path, size, mtime in files:

        try:

            os.remove(path)

            total -= size

            free = shutil.disk_usage(
                DOWNLOAD_DIR
            ).free

            if (
                total <= MAX_BYTES
                and free >= MIN_FREE_BYTES
            ):
                break

        except OSError:
            pass
PY
EOF

chmod +x /usr/local/bin/reclip-cleanup

# ============================================================
# Cron
# ============================================================

cat > /etc/cron.d/reclip-cleanup <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

*/10 * * * * root /usr/local/bin/reclip-cleanup >/dev/null 2>&1
EOF

chmod 644 /etc/cron.d/reclip-cleanup

systemctl enable --now cron

# ============================================================
# Final health checks
# ============================================================

log "Running final health check..."

HEALTH_RESPONSE="$(
    curl -fsS \
        --max-time 10 \
        "http://127.0.0.1:${PORT}/health"
)"

echo "$HEALTH_RESPONSE"

# ============================================================
# Container information
# ============================================================

echo
log "Container configuration:"

docker inspect "$CONTAINER_NAME" \
    --format \
    'Image={{.Config.Image}} Memory={{.HostConfig.Memory}} NanoCPUs={{.HostConfig.NanoCpus}} Pids={{.HostConfig.PidsLimit}}'

echo
log "Container status:"

docker ps \
    --filter "name=${CONTAINER_NAME}"

# ============================================================
# Disk
# ============================================================

echo
log "Disk status:"

df -h /

# ============================================================
# Nginx
# ============================================================

echo
log "Nginx status:"

nginx -t

# ============================================================
# Public test
# ============================================================

echo
log "Testing domain locally through Nginx..."

if curl -kfsS \
    --resolve "${DOMAIN}:443:127.0.0.1" \
    "https://${DOMAIN}/health" \
    >/dev/null 2>&1; then

    log "Nginx HTTPS health check: OK"

else

    warn "Local HTTPS health check failed."
    warn "This may be normal if SSL/Cloudflare is not configured yet."

fi

# ============================================================
# Final
# ============================================================

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
