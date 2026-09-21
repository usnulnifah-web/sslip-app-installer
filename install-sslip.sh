#!/usr/bin/env bash
set -Eeuo pipefail

# Auto installer ScriptStore Provider + temporary sslip.io domain + HTTPS.
# Target: fresh Ubuntu/Debian VPS with a public IPv4 address.

APP_NAME="scriptstore-provider"
APP_DIR="/opt/$APP_NAME"
SERVICE_NAME="$APP_NAME"
REPO_URL="${REPO_URL:-git@github.com:usnulnifah-web/installweb.git}"
BRANCH="${BRANCH:-main}"
DB_NAME="${DB_NAME:-scriptstore}"
DB_USER="${DB_USER:-scriptstore_user}"
PORT="${PORT:-3000}"
ORIGINAL_USER="${SUDO_USER:-}"

log() { printf '\033[1;32m[SSLIP-INSTALL]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARNING]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

[ "${EUID:-$(id -u)}" -eq 0 ] || fail "Jalankan sebagai root: sudo bash install-sslip.sh"
command -v apt-get >/dev/null 2>&1 || fail "Installer ini membutuhkan Ubuntu/Debian dengan apt-get."
command -v systemctl >/dev/null 2>&1 || fail "systemd tidak tersedia."
command -v curl >/dev/null 2>&1 || fail "curl belum terpasang."

# Jika installer dijalankan dengan sudo, tetap gunakan kunci SSH user yang
# memulai installer untuk clone repository privat, bukan kunci root.
if [ -n "$ORIGINAL_USER" ] && [ "$ORIGINAL_USER" != "root" ]; then
  ORIGINAL_HOME="$(getent passwd "$ORIGINAL_USER" | cut -d: -f6 || true)"
  if [ -f "$ORIGINAL_HOME/.ssh/id_ed25519" ]; then
    export GIT_SSH_COMMAND="ssh -i $ORIGINAL_HOME/.ssh/id_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
  elif [ -f "$ORIGINAL_HOME/.ssh/id_rsa" ]; then
    export GIT_SSH_COMMAND="ssh -i $ORIGINAL_HOME/.ssh/id_rsa -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
  fi
fi

if [ -f "$APP_DIR/.env" ] || systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
  warn "Instalasi sebelumnya terdeteksi di $APP_DIR. File aplikasi akan diperbarui dan service akan direstart."
  read -r -p "Ketik REINSTALL-SSL untuk melanjutkan: " CONFIRM
  [ "$CONFIRM" = "REINSTALL-SSL" ] || fail "Instalasi dibatalkan."
fi

export DEBIAN_FRONTEND=noninteractive

log "Memperbarui daftar package..."
apt-get update -y

log "Memasang kebutuhan sistem..."
apt-get install -y ca-certificates curl git openssl nginx certbot python3-certbot-nginx \
  mariadb-server mariadb-client build-essential

if ! command -v node >/dev/null 2>&1 || [ "$(node -p "process.versions.node.split('.')[0]")" -lt 20 ]; then
  log "Memasang Node.js 20..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi

if ! command -v pnpm >/dev/null 2>&1; then
  log "Memasang pnpm..."
  corepack enable 2>/dev/null || true
  corepack prepare pnpm@10.4.1 --activate 2>/dev/null || npm install --global pnpm@10.4.1
fi

command -v node >/dev/null || fail "Node.js gagal dipasang."
command -v pnpm >/dev/null || fail "pnpm gagal dipasang."

log "Mendeteksi IPv4 publik..."
PUBLIC_IP="$(curl -4fsS --max-time 15 https://api.ipify.org || true)"
[ -n "$PUBLIC_IP" ] || PUBLIC_IP="$(curl -4fsS --max-time 15 https://ifconfig.me || true)"
echo "$PUBLIC_IP" | grep -Eq '^[0-9]+(\.[0-9]+){3}$' || fail "IPv4 publik tidak terdeteksi."

DOMAIN="${DOMAIN:-$PUBLIC_IP.sslip.io}"
EMAIL="${EMAIL:-}"

if [ -z "$EMAIL" ]; then
  read -r -p "Email untuk notifikasi SSL Let’s Encrypt: " EMAIL
fi
[ -n "$EMAIL" ] || fail "Email wajib diisi untuk proses SSL."

log "Domain sementara: https://$DOMAIN"

systemctl enable --now mariadb
systemctl enable --now nginx

DB_PASSWORD="$(openssl rand -hex 24)"
JWT_SECRET="$(openssl rand -hex 32)"

log "Membuat database lokal..."
mysql --protocol=socket -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL

DB_URL="mysql://$DB_USER:$DB_PASSWORD@127.0.0.1:3306/$DB_NAME"

log "Mengambil repository aplikasi..."
mkdir -p /opt
if [ -d "$APP_DIR/.git" ]; then
  git -C "$APP_DIR" fetch origin "$BRANCH" --prune
  git -C "$APP_DIR" checkout "$BRANCH"
  git -C "$APP_DIR" reset --hard "origin/$BRANCH"
else
  rm -rf "$APP_DIR"
  git clone --branch "$BRANCH" "$REPO_URL" "$APP_DIR"
fi

cd "$APP_DIR"

cat > .env <<EOF
PORT=$PORT
NODE_ENV=production
DATABASE_URL=$DB_URL
JWT_SECRET=$JWT_SECRET

APP_BASE_URL=https://$DOMAIN

SMTP_HOST=
SMTP_PORT=587
SMTP_SECURE=false
SMTP_USER=
SMTP_PASSWORD=
SMTP_FROM=

GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=

VITE_APP_ID=
VITE_OAUTH_PORTAL_URL=
OAUTH_SERVER_URL=
BUILT_IN_FORGE_API_URL=
BUILT_IN_FORGE_API_KEY=
VITE_FRONTEND_FORGE_API_URL=
VITE_FRONTEND_FORGE_API_KEY=
OWNER_OPEN_ID=
OWNER_NAME=
EOF
chmod 600 .env

log "Menginstall dependency dan menyiapkan database..."
pnpm install --frozen-lockfile
pnpm db:push
pnpm check
pnpm build

log "Membuat service systemd..."
cat > "/etc/systemd/system/$SERVICE_NAME.service" <<EOF
[Unit]
Description=ScriptStore Provider
After=network.target mariadb.service
Wants=mariadb.service

[Service]
Type=simple
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/.env
ExecStart=$(command -v node) $APP_DIR/dist/index.js
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"
sleep 3
systemctl is-active --quiet "$SERVICE_NAME" || {
  journalctl -u "$SERVICE_NAME" --no-pager -n 80
  fail "Service aplikasi gagal berjalan."
}

log "Menyiapkan Nginx..."
rm -f /etc/nginx/sites-enabled/default
cat > /etc/nginx/sites-available/$APP_NAME <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    client_max_body_size 25M;

    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
ln -sfn /etc/nginx/sites-available/$APP_NAME /etc/nginx/sites-enabled/$APP_NAME
nginx -t
systemctl reload nginx

log "Meminta sertifikat SSL Let’s Encrypt..."
certbot --nginx \
  --non-interactive \
  --agree-tos \
  --email "$EMAIL" \
  --redirect \
  -d "$DOMAIN"

systemctl enable --now certbot.timer 2>/dev/null || true

if command -v ufw >/dev/null 2>&1; then
  ufw allow OpenSSH >/dev/null 2>&1 || true
  ufw allow 'Nginx Full' >/dev/null 2>&1 || true
fi

cat > /root/$APP_NAME-install-info.txt <<EOF
APP_URL=https://$DOMAIN
APP_DIR=$APP_DIR
SERVICE=$SERVICE_NAME
DATABASE_NAME=$DB_NAME
DATABASE_USER=$DB_USER
DATABASE_PASSWORD=$DB_PASSWORD
DATABASE_URL=$DB_URL
JWT_SECRET=$JWT_SECRET
SSL_RENEWAL=certbot.timer
EOF
chmod 600 /root/$APP_NAME-install-info.txt

printf '\n'
printf '============================================================\n'
printf 'INSTALASI BERHASIL\n'
printf '============================================================\n'
printf 'URL: https://%s\n' "$DOMAIN"
printf 'Folder: %s\n' "$APP_DIR"
printf 'Service: %s\n' "$SERVICE_NAME"
printf 'Info rahasia: /root/%s-install-info.txt\n' "$APP_NAME"
printf '\n' 
printf 'Buka URL di browser dan buat akun admin pertama.\n'
printf '============================================================\n'
