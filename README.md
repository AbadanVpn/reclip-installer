# ReClip Installer 

نصب، مدیریت، به‌روزرسانی و حذف خودکار **ReClip** روی سرورهای Ubuntu/Debian با Docker و Nginx.

این پروژه برای نصب سریع و Production-ready سرویس ReClip طراحی شده است؛ به‌طوری‌که کاربر بتواند تنها با یک دستور، کل سرویس را روی VPS راه‌اندازی کند.

---

## ✨ امکانات

* نصب خودکار ReClip
* نصب Docker و Docker Compose در صورت نیاز
* نصب و تنظیم Nginx
* اتصال دامنه به ReClip
* پشتیبانی از HTTPS
* پشتیبانی از Let's Encrypt
* دریافت ویدئو با `yt-dlp`
* تبدیل ویدئو به MP4
* استخراج صدا به MP3
* محدودیت همزمانی دانلودها
* محدودیت CPU و RAM کانتینر
* محدودیت تعداد Processها
* پاک‌سازی خودکار فایل‌های قدیمی
* محدودیت فضای دانلودها
* Health Check
* Rate Limit برای API
* پشتیبانی از Cloudflare
* Backup قبل از نصب مجدد
* به‌روزرسانی ساده
* Uninstall کامل
* اجرای سرویس به‌صورت Docker container
* Restart خودکار بعد از reboot

---

# 🖥️ مشخصات پیشنهادی سرور

برای اجرای معمولی:

| مورد       |            مقدار پیشنهادی |
| ---------- | ------------------------: |
| CPU        |                   2 vCore |
| RAM        |                      4 GB |
| Storage    |                    50+ GB |
| سیستم‌عامل |        Ubuntu 24.04/26.04 |
| Docker     |                    الزامی |
| Nginx      | توسط Installer نصب می‌شود |

برای سرورهای کوچک نیز امکان اجرا وجود دارد، اما تعداد دانلودهای همزمان باید پایین نگه داشته شود.

---

# 🌐 پیش‌نیاز دامنه

قبل از نصب، دامنه را به IP سرور متصل کنید.

مثلاً:

```text
reclip.example.com
        ↓
      VPS IP
```

اگر از Cloudflare استفاده می‌کنید:

```text
DNS
 ↓
A Record
 ↓
reclip.example.com
 ↓
SERVER_IP
```

توصیه می‌شود Proxy کلادفلر فعال باشد.

---

# 🚀 نصب سریع

## نصب با یک دستور

اگر فایل Installer را مستقیماً از GitHub اجرا می‌کنید:

```bash
curl -fsSL https://raw.githubusercontent.com/AbadanVpn/reclip-installer/main/install.sh | sudo bash -s -- reclip.example.com
```

به جای:

```text
reclip.example.com
```

دامنه خودتان را قرار دهید.

---

# 🔐 نصب با Let's Encrypt

اگر می‌خواهید Installer برای دامنه گواهی SSL دریافت کند:

```bash
curl -fsSL https://raw.githubusercontent.com/AbadanVpn/reclip-installer/main/install.sh | sudo bash -s -- reclip.example.com admin@example.com
```

پارامتر دوم ایمیل Certbot است.

مثلاً:

```bash
sudo bash install.sh reclip.example.com admin@example.com
```

---

# 📦 نصب از Repository

روش دیگر:

```bash
git clone https://github.com/AbadanVpn/reclip-installer.git
cd reclip-installer
sudo bash install.sh reclip.example.com
```

با Let's Encrypt:

```bash
sudo bash install.sh reclip.example.com admin@example.com
```

---

# 📁 ساختار پروژه

```text
reclip-installer/
│
├── install.sh
├── update.sh
├── uninstall.sh
└── README.md
```

Installer بعد از اجرا پروژه ReClip را در مسیر زیر قرار می‌دهد:

```text
/opt/reclip
```

---

# ⚙️ تنظیمات Production

نسخه Production دارای محدودیت‌های زیر است:

```text
CPU:
1.8 vCPU

RAM:
3 GB

Maximum Swap:
4 GB

PIDs:
128

Concurrent Downloads:
2
```

این تنظیمات برای VPS چهار گیگابایتی در نظر گرفته شده‌اند.

---

# 💾 مدیریت فایل‌های دانلود

فایل‌های دانلود شده در Docker Volume ذخیره می‌شوند:

```text
reclip-downloads
```

مسیر داخل کانتینر:

```text
/app/downloads
```

---

## محدودیت فضای دانلود

به‌صورت پیش‌فرض:

```text
Maximum download storage:
70 GB
```

حداقل فضای آزاد سیستم:

```text
10 GB
```

فایل‌هایی که بیشتر از:

```text
30 minutes
```

قدمت داشته باشند، به‌صورت خودکار حذف می‌شوند.

---

# 🧹 پاک‌سازی دستی

Installer اسکریپت زیر را ایجاد می‌کند:

```bash
/usr/local/bin/reclip-cleanup
```

برای اجرای دستی:

```bash
sudo /usr/local/bin/reclip-cleanup
```

پاک‌سازی خودکار نیز هر ۱۰ دقیقه اجرا می‌شود.

Cron:

```text
*/10 * * * *
```

---

# 🔄 Update

برای به‌روزرسانی ReClip:

```bash
curl -fsSL https://raw.githubusercontent.com/AbadanVpn/reclip-installer/main/update.sh | sudo bash -s -- reclip.example.com
```

یا اگر Repository را clone کرده‌اید:

```bash
cd reclip-installer
sudo bash update.sh reclip.example.com
```

---

## Update چه کاری انجام می‌دهد؟

اسکریپت Update:

1. وضعیت سرویس را بررسی می‌کند.
2. از فایل‌های مهم Backup می‌گیرد.
3. سورس پروژه را به‌روزرسانی می‌کند.
4. Docker image جدید می‌سازد.
5. کانتینر قبلی را متوقف می‌کند.
6. کانتینر جدید را اجرا می‌کند.
7. Health Check انجام می‌دهد.
8. وضعیت نهایی را نمایش می‌دهد.

---

# 🔍 بررسی وضعیت

مشاهده کانتینر:

```bash
docker ps
```

باید چیزی مشابه زیر ببینید:

```text
reclip:production
reclip
127.0.0.1:8899->8899/tcp
```

---

# 📊 مشاهده مصرف منابع

```bash
docker stats reclip
```

---

# 📜 مشاهده Log

```bash
docker logs -f reclip
```

یا:

```bash
docker logs --tail 100 reclip
```

---

# ❤️ Health Check

ReClip دارای endpoint زیر است:

```text
/health
```

مثلاً:

```bash
curl http://127.0.0.1:8899/health
```

پاسخ موفق مشابه:

```json
{
  "status": "ok",
  "service": "reclip",
  "max_concurrent_downloads": 2
}
```

از طریق دامنه نیز:

```bash
curl https://reclip.example.com/health
```

---

# 🔒 HTTPS

Nginx به‌عنوان Reverse Proxy استفاده می‌شود.

ساختار:

```text
User
  │
  ▼
Cloudflare
  │
  ▼
HTTPS
  │
  ▼
Nginx :443
  │
  ▼
127.0.0.1:8899
  │
  ▼
Docker
  │
  ▼
ReClip
```

Port سرویس ReClip مستقیماً روی اینترنت باز نمی‌شود.

تنها:

```text
127.0.0.1:8899
```

استفاده می‌شود.

---

# ☁️ Cloudflare

ReClip با Cloudflare قابل استفاده است.

DNS:

```text
A
reclip.example.com
SERVER_IP
```

در صورت استفاده از Proxy:

```text
Proxy: ON
```

Installer همچنین IP Rangeهای رسمی Cloudflare را برای Real IP در Nginx دریافت می‌کند.

---

# 🛡️ Rate Limit

برای جلوگیری از Abuse، APIها دارای محدودیت هستند.

## `/api/info`

حدود:

```text
10 requests/minute
```

با Burst محدود.

---

## `/api/download`

حدود:

```text
3 requests/minute
```

با Burst محدود.

---

# 🎥 API

## دریافت اطلاعات ویدئو

```http
POST /api/info
```

نمونه:

```bash
curl -X POST \
  -H "Content-Type: application/json" \
  -d '{"url":"https://youtu.be/VIDEO_ID"}' \
  https://reclip.example.com/api/info
```

---

## دانلود

```http
POST /api/download
```

نمونه:

```json
{
  "url": "https://youtu.be/VIDEO_ID",
  "format": "video",
  "format_id": "312",
  "title": "Example Video"
}
```

---

## بررسی وضعیت Job

```http
GET /api/status/JOB_ID
```

مثلاً:

```bash
curl https://reclip.example.com/api/status/68f4ae81f3
```

پاسخ:

```json
{
  "status": "done",
  "error": null,
  "filename": "Example Video.mp4"
}
```

---

## دریافت فایل

```http
GET /api/file/JOB_ID
```

مثلاً:

```bash
curl -OJ \
  https://reclip.example.com/api/file/68f4ae81f3
```

---

# 🎵 MP3

برای استخراج صدا:

```json
{
  "url": "https://youtu.be/VIDEO_ID",
  "format": "audio"
}
```

خروجی:

```text
MP3
```

---

# 📋 Playlist

Endpoint:

```http
POST /api/playlist
```

نمونه:

```bash
curl -X POST \
  -H "Content-Type: application/json" \
  -d '{"url":"PLAYLIST_URL"}' \
  https://reclip.example.com/api/playlist
```

---

# 🐳 Docker

مشاهده image:

```bash
docker images | grep reclip
```

مشاهده کانتینر:

```bash
docker ps -a --filter name=reclip
```

Restart:

```bash
docker restart reclip
```

---

# 🔁 Restart سرویس

```bash
cd /opt/reclip
docker compose restart
```

یا:

```bash
docker restart reclip
```

---

# 🛠️ Rebuild

برای Build مجدد:

```bash
cd /opt/reclip
docker compose build --pull
docker compose up -d --force-recreate
```

---

# 🗃️ Backup

Installer قبل از تغییرات مهم Backup ایجاد می‌کند.

مسیر:

```text
/opt/reclip-backups
```

مثال:

```text
/opt/reclip-backups/
└── reclip-20260901-120000/
```

---

# 🗑️ Uninstall

برای حذف کامل:

```bash
curl -fsSL https://raw.githubusercontent.com/AbadanVpn/reclip-installer/main/uninstall.sh | sudo bash -s -- reclip.example.com
```

یا:

```bash
cd reclip-installer
sudo bash uninstall.sh reclip.example.com
```

---

# ⚠️ توجه مهم درباره Uninstall

قبل از حذف، اسکریپت باید سرویس را متوقف کرده و منابع ReClip را حذف کند.

موارد مربوط به ReClip شامل:

```text
Docker container
Docker image
Docker volume
Nginx configuration
Cleanup script
Cron job
Application directory
```

حذف می‌شوند.

---

# ⚠️ حذف Volume

Volume دانلودها شامل فایل‌های دانلود شده است.

در صورت حذف Volume:

```text
reclip-downloads
```

تمام فایل‌های دانلود شده نیز حذف خواهند شد.

بنابراین قبل از Uninstall در صورت نیاز Backup بگیرید.

---

# 🔐 امنیت

ReClip نباید با دسترسی root داخل کانتینر اجرا شود.

Container با user زیر اجرا می‌شود:

```text
reclip
```

همچنین:

```text
no-new-privileges
```

فعال است.

---

# 🚦 محدودیت دانلود همزمان

پیش‌فرض:

```text
2 دانلود همزمان
```

این مقدار برای VPS دارای:

```text
4 GB RAM
2 vCPU
```

مناسب است.

افزایش آن ممکن است مصرف CPU/RAM و پهنای باند را بالا ببرد.

---

# 🧪 تست بعد از نصب

بعد از نصب ابتدا:

```bash
docker ps
```

سپس:

```bash
curl http://127.0.0.1:8899/health
```

بعد:

```bash
curl -I https://reclip.example.com
```

و در نهایت سایت را در مرورگر باز کنید:

```text
https://reclip.example.com
```

---

# 🩺 عیب‌یابی

## Container اجرا نمی‌شود

```bash
docker ps -a
```

سپس:

```bash
docker logs reclip
```

---

## بررسی Nginx

```bash
nginx -t
```

اگر موفق باشد:

```text
syntax is ok
test is successful
```

سپس:

```bash
systemctl reload nginx
```

---

## بررسی Port

```bash
ss -lntp | grep 8899
```

باید سرویس روی:

```text
127.0.0.1:8899
```

باشد.

---

## بررسی دامنه

```bash
curl -I https://reclip.example.com
```

اگر Cloudflare فعال باشد معمولاً:

```text
HTTP/2 200
server: cloudflare
```

مشاهده می‌شود.

---

# 📋 فایل‌های مهم روی سرور

```text
/opt/reclip/
```

Application:

```text
/opt/reclip/app.py
```

Dockerfile:

```text
/opt/reclip/Dockerfile
```

Compose:

```text
/opt/reclip/docker-compose.yml
```

Template:

```text
/opt/reclip/templates/
```

Static:

```text
/opt/reclip/static/
```

Installer Log:

```text
/var/log/reclip-installer.log
```

Cleanup:

```text
/usr/local/bin/reclip-cleanup
```

Nginx:

```text
/etc/nginx/sites-available/DOMAIN
```

---

# 📌 نکته درباره Git

Installer پروژه اصلی ReClip را از Repository مشخص‌شده دریافت می‌کند و فایل‌های Production موردنیاز را روی سرور تنظیم می‌کند.

Repository Installer:

**AbadanVpn/reclip-installer**

---

# 🔄 چرخه مدیریت

ساختار پیشنهادی استفاده:

```text
INSTALL
   │
   ▼
install.sh
   │
   ▼
Production
   │
   ├── docker
   ├── nginx
   ├── ssl
   ├── cleanup
   └── health
   │
   ▼
UPDATE
   │
   ▼
update.sh
   │
   ▼
Backup → Build → Deploy → Health Check
   │
   ▼
Production
```

برای حذف:

```text
Production
   │
   ▼
uninstall.sh
   │
   ▼
Cleanup
```

---

# ⚡ خلاصه دستورات

### Install

```bash
sudo bash install.sh reclip.example.com
```

### Install + SSL

```bash
sudo bash install.sh reclip.example.com admin@example.com
```

### Update

```bash
sudo bash update.sh reclip.example.com
```

### Uninstall

```bash
sudo bash uninstall.sh reclip.example.com
```

### Logs

```bash
docker logs -f reclip
```

### Stats

```bash
docker stats reclip
```

### Restart

```bash
docker restart reclip
```

### Health

```bash
curl http://127.0.0.1:8899/health
```

### Nginx test

```bash
nginx -t
```

### Cleanup

```bash
sudo /usr/local/bin/reclip-cleanup
```

---

# 📄 License

این Repository مطابق License پروژه و فایل `LICENSE` موجود در Repository اصلی منتشر می‌شود.

قبل از استفاده تجاری، شرایط License پروژه اصلی ReClip و وابستگی‌های آن را بررسی کنید.

---

# ⚠️ مسئولیت استفاده

این Installer صرفاً ابزار نصب و مدیریت سرویس ReClip است.

کاربر مسئول اطمینان از قانونی بودن محتوایی است که از طریق سرویس دانلود می‌کند و باید قوانین سرویس‌های شخص ثالث، قوانین کپی‌رایت و قوانین محل استفاده را رعایت کند.

---

# 👤 Maintainer

**AbadanVpn**

Repository:

```text
AbadanVpn/reclip-installer
```

هدف پروژه:

```text
One-command production deployment for ReClip
```
