#!/usr/bin/env bash
# deploy.sh - Fully automated Laravel deploy (single-command)
# Tested conceptually on Ubuntu 22.04/24.04. Edit the top variables before running.
set -euo pipefail
IFS=$'\n\t'

### -------------------------
### EDIT THESE BEFORE RUNNING
### -------------------------
REPO="https://github.com/mtpl-dev-6/my-laravel-site.git"   # OK (public)
BRANCH="main"                                              # OK
DOMAIN="local-test.com"                                    # see notes below
APP_USER="www-data"                                        # OK (or set your linux username)
APP_DIR="/var/www/Desktop/my-laravel-site"                                 # OK
PHP_VERSION="8.4"
DB_NAME="laravel_db"                                       # OK
DB_USER="laravel_user"                                     # OK
DB_PASS=""                                                 # leave empty to auto-generate or set a password
EMAIL_FOR_CERT="admin@${DOMAIN}"                           # used by certbot; not important for local tests
# used by certbot for expiration notices
### -------------------------

# helper: random password
randpass() {
  # 20 char random
  tr -dc 'A-Za-z0-9!@#$%_\-+=' < /dev/urandom | head -c 20 || true
}

if [ -z "$DB_PASS" ]; then
  DB_PASS="$(randpass)"
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root: sudo bash deploy.sh"
  exit 2
fi

echo "Starting automated Laravel deployment for $DOMAIN"
echo "Repo: $REPO (branch: $BRANCH)"
echo "App dir: $APP_DIR"
echo

# Basic apt update + install
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt upgrade -y

# Install core packages
apt install -y nginx git curl unzip software-properties-common ca-certificates lsb-release apt-transport-https

# Install PHP & extensions
# Add PPA if necessary (Ubuntu usually has needed PHP)
apt update -y
apt install -y \
    php${PHP_VERSION} php${PHP_VERSION}-fpm php${PHP_VERSION}-cli php${PHP_VERSION}-mbstring \
    php${PHP_VERSION}-xml php${PHP_VERSION}-curl php${PHP_VERSION}-zip php${PHP_VERSION}-gd \
    php${PHP_VERSION}-mysql php${PHP_VERSION}-bcmath php${PHP_VERSION}-tokenizer php${PHP_VERSION}-intl

# Install and secure MySQL (server)
apt install -y mysql-server

# Start mysql (ensure running)
systemctl enable --now mysql

# Create DB and user (non-interactive)
echo "Creating MySQL database and user..."
mysql --execute="CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;"

# Install Composer (global)
if ! command -v composer >/dev/null 2>&1; then
  echo "Installing Composer..."
  curl -sS https://getcomposer.org/installer -o /tmp/composer-setup.php
  php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
  rm -f /tmp/composer-setup.php
fi

# Install Node.js & npm (LTS)
if ! command -v node >/dev/null 2>&1; then
  echo "Installing Node.js..."
  curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
  apt install -y nodejs
fi

# Install Certbot (snap) if not present
if ! command -v certbot >/dev/null 2>&1; then
  echo "Installing Certbot (snap)..."
  apt install -y snapd
  snap install core; snap refresh core
  snap install --classic certbot
  ln -s /snap/bin/certbot /usr/bin/certbot || true
fi

# Create app dir & clone repo
mkdir -p "$APP_DIR"
chown -R $APP_USER:$APP_USER "$APP_DIR" || true
rm -rf "$APP_DIR"/*
echo "Cloning repo..."
git clone --depth 1 --branch "$BRANCH" "$REPO" "$APP_DIR"

# Ensure permissions for subsequent steps
chown -R "$APP_USER":"$APP_USER" "$APP_DIR"

# Move into app dir
cd "$APP_DIR"

# If repo has subdir (like in some setups) it's up to user to adapt.
# Install composer deps
echo "Installing Composer dependencies..."
sudo -u "$APP_USER" composer install --no-interaction --prefer-dist --optimize-autoloader

# Create .env if not exists; base on example or create from scratch
if [ ! -f .env ]; then
  if [ -f .env.example ]; then
    cp .env.example .env
  else
    cat > .env <<EOF
APP_NAME=${DOMAIN}
APP_ENV=production
APP_KEY=
APP_DEBUG=false
APP_URL=https://${DOMAIN}

LOG_CHANNEL=stack

DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USER}
DB_PASSWORD=${DB_PASS}

BROADCAST_DRIVER=log
CACHE_DRIVER=file
QUEUE_CONNECTION=database
SESSION_DRIVER=file
SESSION_LIFETIME=120
EOF
  fi
fi

# Write DB credentials (override safely)
php -r "
\$env = file_get_contents('.env');
\$env = preg_replace('/^DB_DATABASE=.*/m', 'DB_DATABASE=${DB_NAME}', \$env);
\$env = preg_replace('/^DB_USERNAME=.*/m', 'DB_USERNAME=${DB_USER}', \$env);
\$env = preg_replace('/^DB_PASSWORD=.*/m', 'DB_PASSWORD=${DB_PASS}', \$env);
file_put_contents('.env', \$env);
"

# Generate key
echo "Generating APP_KEY..."
sudo -u "$APP_USER" php artisan key:generate --force

# Cache config/routes/views
sudo -u "$APP_USER" php artisan config:cache || true
sudo -u "$APP_USER" php artisan route:cache || true
sudo -u "$APP_USER" php artisan view:cache || true

# Run migrations + seed if desired (non-interactive)
echo "Running migrations..."
sudo -u "$APP_USER" php artisan migrate --force

# Ensure storage link
sudo -u "$APP_USER" php artisan storage:link || true

# NPM install & build (if package.json exists)
if [ -f package.json ]; then
  echo "Installing NPM packages and building frontend..."
  sudo -u "$APP_USER" npm install --no-audit --no-fund
  # If Laravel Mix or Vite is used, run build. Try both heuristics.
  if grep -q "vite" package.json 2>/dev/null; then
    sudo -u "$APP_USER" npm run build
  else
    sudo -u "$APP_USER" npm run prod || sudo -u "$APP_USER" npm run build || true
  fi
fi

# Permissions for Laravel folders
chown -R "$APP_USER":"$APP_USER" "$APP_DIR"
find "$APP_DIR" -type f -exec chmod 644 {} \;
find "$APP_DIR" -type d -exec chmod 755 {} \;
chmod -R ug+rwx storage bootstrap/cache

# Nginx site configuration
NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}"
PHP_FPM_SOCK="/run/php/php${PHP_VERSION}-fpm.sock"
if [ ! -f "$NGINX_CONF" ]; then
  cat > "$NGINX_CONF" <<NGCONF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};

    root ${APP_DIR}/public;
    index index.php index.html index.htm;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_FPM_SOCK};
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
NGCONF

  ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/${DOMAIN}"
fi

# Test nginx config and reload
nginx -t
systemctl enable --now nginx
systemctl reload nginx || true

# Obtain Let's Encrypt cert (will prompt if manual action required)
echo "Attempting to obtain TLS certificate via certbot..."
# Use --noninteractive and --agree-tos where possible
certbot_cmd="certbot --nginx -d ${DOMAIN} -d www.${DOMAIN} --email ${EMAIL_FOR_CERT} --non-interactive --agree-tos --redirect"
if $certbot_cmd >/dev/null 2>&1; then
  echo "Certificate obtained and nginx reloaded (auto-redirect to HTTPS)."
else
  echo "Certbot automated run failed or requires interaction. Attempting a manual certbot certonly + reload..."
  certbot certonly --webroot -w "${APP_DIR}/public" -d "${DOMAIN}" -d "www.${DOMAIN}" --email "${EMAIL_FOR_CERT}" --non-interactive --agree-tos || true
  systemctl reload nginx || true
  echo "If certbot could not automatically obtain a cert, please run 'certbot --nginx -d ${DOMAIN} -d www.${DOMAIN}' manually to complete TLS setup."
fi

# Provide DB credentials backup file
echo "Writing credentials to /root/${DOMAIN}_deploy_credentials.txt"
cat > /root/${DOMAIN}_deploy_credentials.txt <<CRED
Deployment summary for ${DOMAIN}
APP_DIR=${APP_DIR}
REPO=${REPO}
BRANCH=${BRANCH}

MySQL database: ${DB_NAME}
MySQL user: ${DB_USER}
MySQL password: ${DB_PASS}

Web user: ${APP_USER}

To manage the site:
 - cd ${APP_DIR}
 - php artisan (for artisan commands)
 - sudo systemctl status nginx php${PHP_VERSION}-fpm mysql

CRED
chmod 600 /root/${DOMAIN}_deploy_credentials.txt

echo
echo "--------------------------------------------------"
echo "Deployment finished (may require minor manual steps)."
echo " - App is in: ${APP_DIR}"
echo " - Credentials saved: /root/${DOMAIN}_deploy_credentials.txt (permissions 600)"
echo " - Check nginx: systemctl status nginx"
echo " - Check php-fpm: systemctl status php${PHP_VERSION}-fpm"
echo " - If certbot failed, run: certbot --nginx -d ${DOMAIN} -d www.${DOMAIN}"
echo "If something fails, inspect /var/log/nginx/error.log and Laravel logs in storage/logs."
echo "--------------------------------------------------"
