#!/bin/bash

#==============================================================================
# PHP Application Deployment Script
# Description: Zero-downtime deployment for PHP (Laravel-ready) Apps via Nginx
# Author: DevOps Engineer (Adapted from React/Node script)
# Version: 1.0.0
#==============================================================================

# --- SHELL SAFETY ---
set -euo pipefail
IFS=$'\n\t'

#==============================================================================
# COLOR CODES
#==============================================================================
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

#==============================================================================
# LOGGING
#==============================================================================
log_info()     { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
log_success()  { echo -e "${GREEN}[✓]${NC} $1" >&2; }
log_warning()  { echo -e "${YELLOW}[⚠]${NC} $1" >&2; }
log_error()    { echo -e "${RED}[✗]${NC} $1" >&2; exit 1; }
log_section() {
    echo "" >&2
    echo -e "${MAGENTA}╔════════════════════════════════════════════════════════╗${NC}" >&2
    echo -e "${MAGENTA}║ $1${NC}" >&2
    echo -e "${MAGENTA}╚════════════════════════════════════════════════════════╝${NC}" >&2
}

#==============================================================================
# CONFIGURATION (Dynamic defaults)
#==============================================================================
PROJECT_NAME="${PROJECT_NAME:-php-app}"
DOMAIN="${DOMAIN:-example.com}"
GIT_REPO="${GIT_REPO:-https://github.com/your/repo.git}"    # Must be provided
GIT_BRANCH="${GIT_BRANCH:-main}"
ENVIRONMENT="${ENVIRONMENT:-production}"

# Paths
BASE_DIR="/var/www"
DOMAIN_DIR="${BASE_DIR}/${DOMAIN}"
RELEASES_DIR="${DOMAIN_DIR}/releases"
CURRENT_DIR="${DOMAIN_DIR}/current"        # symlink -> release_path (for nginx root)
SHARED_DIR="${DOMAIN_DIR}/shared"
BACKUP_DIR="${DOMAIN_DIR}/backups"
LOG_DIR="${DOMAIN_DIR}/logs"

# PHP / Composer
PHP_BIN="${PHP_BIN:-php}"
COMPOSER_BIN="${COMPOSER_BIN:-composer}"
PHP_FPM_SOCK="${PHP_FPM_SOCK:-/run/php/php8.1-fpm.sock}"   # adjust if needed
PHP_VERSION="${PHP_VERSION:-8.1}"

# Nginx / SSL
NGINX_PORT="${NGINX_PORT:-80}"
SSL_ENABLED="${SSL_ENABLED:-false}"
EMAIL="${EMAIL:-admin@${DOMAIN}}"

# Settings
KEEP_RELEASES="${KEEP_RELEASES:-5}"
DEPLOY_USER="${DEPLOY_USER:-$USER}"
DEPLOY_GROUP="${DEPLOY_GROUP:-www-data}"
SHARED_SYMLINKS="${SHARED_SYMLINKS:-.env,storage,public/uploads}"  # Comma separated path(s) relative to repo root

# Optional Laravel settings
IS_LARAVEL="${IS_LARAVEL:-true}"   # set false for plain PHP
ARTISAN="${ARTISAN:-artisan}"      # path to artisan within release (usually 'artisan')

# System
SERVER_IP=$(hostname -I | awk '{print $1}' || echo "127.0.0.1")

#==============================================================================
# ERROR HANDLER
#==============================================================================
error_exit() {
    log_error "Deployment failed at line ${BASH_LINENO[0]} (Exit Code $?)"
}
trap error_exit ERR

#==============================================================================
# 1. VALIDATION
#==============================================================================
validate_config() {
    log_section "🔍 Validating Configuration"
    [[ -z "$DOMAIN" ]] && log_error "DOMAIN is required"
    [[ -z "$GIT_REPO" ]] && log_error "GIT_REPO is required"

    # Create main directories if missing (permissions set later)
    sudo mkdir -p "${BASE_DIR}"
    sudo chown -R "${DEPLOY_USER}:${DEPLOY_GROUP}" "${BASE_DIR}"

    log_info "Target: ${DOMAIN} (${GIT_BRANCH})"
    log_success "Configuration valid"
}

#==============================================================================
# 2. SYSTEM PREP
#==============================================================================
install_dependencies() {
    log_section "📦 System Dependencies"
    # Minimal install - you may want to expand packages to match your distro
    local packages=( "git" "nginx" "php${PHP_VERSION%-*}" "php${PHP_VERSION}-fpm" "php${PHP_VERSION}-cli" "php-xml" "php-mbstring" "php-zip" "php-curl" "unzip" "acl" "certbot" "python3-certbot-nginx" )
    log_info "Ensuring essential packages are installed (this may be idempotent)..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}" >/dev/null 2>&1 || true

    # Ensure nginx running
    if ! systemctl is-active --quiet nginx; then
        sudo systemctl enable --now nginx
    fi

    # Ensure php-fpm running
    if ! systemctl is-active --quiet "php${PHP_VERSION}-fpm"; then
        sudo systemctl enable --now "php${PHP_VERSION}-fpm" || true
    fi

    # Ensure composer available
    if ! command -v "${COMPOSER_BIN}" &>/dev/null; then
        log_info "Composer not found - installing globally..."
        EXPECTED_HASH="$(wget -q -O - https://composer.github.io/installer.sig)" || true
        php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" >/dev/null 2>&1
        php composer-setup.php --install-dir=/usr/local/bin --filename=composer >/dev/null 2>&1
        rm -f composer-setup.php
    fi

    log_success "Dependencies ready"
}

setup_directories() {
    log_section "📁 Directory Structure"
    sudo mkdir -p "${DOMAIN_DIR}" "${RELEASES_DIR}" "${SHARED_DIR}" "${BACKUP_DIR}" "${LOG_DIR}" "${CURRENT_DIR}"
    sudo chown -R "${DEPLOY_USER}:${DEPLOY_GROUP}" "${DOMAIN_DIR}"
    sudo chmod -R 775 "${DOMAIN_DIR}"

    # Create shared items (files/dirs)
    IFS=',' read -ra DIRS <<< "$SHARED_SYMLINKS"
    for item in "${DIRS[@]}"; do
        # Trim whitespace
        item="$(echo -e "${item}" | tr -d '[:space:]')"
        shared_path="${SHARED_DIR}/${item}"
        if [[ "${item}" == */ ]] || [[ "${item}" != *.* ]]; then
            # Looks like a directory
            sudo mkdir -p "${shared_path}"
        else
            # Treat as file or directory - create parent and file if not exists
            sudo mkdir -p "$(dirname "${shared_path}")"
            if [[ ! -e "${shared_path}" ]]; then
                sudo touch "${shared_path}"
                sudo chown "${DEPLOY_USER}:${DEPLOY_GROUP}" "${shared_path}"
            fi
        fi
    done

    log_success "Directories created at ${DOMAIN_DIR}"
}

#==============================================================================
# 3. CLONE & PREPARE RELEASE
#==============================================================================
clone_and_prepare() {
    log_section "🏗️ Clone & Prepare Release"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local release_path="${RELEASES_DIR}/${timestamp}"

    log_info "Cloning ${GIT_REPO} (branch: ${GIT_BRANCH})..."
    sudo -u "${DEPLOY_USER}" git clone --quiet --depth 1 --branch "${GIT_BRANCH}" "${GIT_REPO}" "${release_path}"
    cd "${release_path}"

    # Link shared items into the release
    IFS=',' read -ra LINKS <<< "$SHARED_SYMLINKS"
    for item in "${LINKS[@]}"; do
        item="$(echo -e "${item}" | tr -d '[:space:]')"
        target="${release_path}/${item}"
        source="${SHARED_DIR}/${item}"

        # Remove any existing path in repo
        if [[ -e "${target}" || -L "${target}" ]]; then
            rm -rf "${target}"
        fi

        # Ensure parent exists for target and create symlink
        mkdir -p "$(dirname "${target}")"
        ln -sfn "${source}" "${target}"
        log_info "Linked shared item: ${item}"
    done

    # Composer install (production)
    if [[ -f "composer.json" ]]; then
        log_info "Installing Composer dependencies (no-dev)..."
        sudo -u "${DEPLOY_USER}" "${COMPOSER_BIN}" install --no-dev --prefer-dist --no-interaction --optimize-autoloader >/dev/null 2>&1 || {
            log_warning "Composer install returned non-zero status (continuing for debugging)"
        }
    fi

    # Laravel-specific: storage link, config cache, migrate (performed during finalize)
    echo "${release_path}"
}

#==============================================================================
# 4. NGINX CONFIGURATION
#==============================================================================
configure_nginx() {
    log_section "🌐 Nginx Configuration"
    local nginx_conf="/etc/nginx/sites-available/${DOMAIN}.conf"
    local web_root="${CURRENT_DIR}"

    # If Laravel set webroot to current/public
    if [[ "${IS_LARAVEL}" == "true" ]]; then
        web_root="${CURRENT_DIR}/public"
    fi

    sudo tee "${nginx_conf}" > /dev/null <<EOF
server {
    listen ${NGINX_PORT} default_server;
    server_name ${DOMAIN} www.${DOMAIN};
    root ${web_root};
    index index.php index.html index.htm;

    access_log ${LOG_DIR}/nginx_access.log;
    error_log ${LOG_DIR}/nginx_error.log warn;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Content-Type-Options "nosniff";

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    # PHP-FPM handling
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_FPM_SOCK};
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    # Static files caching
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2|ttf|eot)$ {
        expires 30d;
        access_log off;
        add_header Cache-Control "public, no-transform";
    }

    # Deny access to .env and other sensitive files
    location ~ /\.(env|git) {
        deny all;
    }
}
EOF

    sudo ln -sf "${nginx_conf}" "/etc/nginx/sites-enabled/${DOMAIN}.conf"

    if sudo nginx -t >/dev/null 2>&1; then
        sudo systemctl reload nginx
        log_success "Nginx configured and reloaded for ${DOMAIN}"
    else
        log_error "Nginx config test failed"
    fi
}

setup_ssl() {
    if [[ "${SSL_ENABLED}" == "true" ]]; then
        log_section "🔒 SSL Configuration (Certbot)"
        # Avoid re-requesting cert if it exists
        if ! sudo certbot certificates 2>/dev/null | grep -q "${DOMAIN}"; then
            sudo certbot --nginx -d "${DOMAIN}" -d "www.${DOMAIN}" \
                --non-interactive --agree-tos -m "${EMAIL}" --redirect
            log_success "SSL Certificate installed"
        else
            log_info "SSL Certificate already exists"
        fi
    fi
}

#==============================================================================
# 5. FINALIZE DEPLOYMENT (Atomic swap + post-deploy tasks)
#==============================================================================
finalize_deploy() {
    local release_path=$1
    log_section "🚀 Finalizing Deployment"
    cd "${release_path}"

    # Ensure correct permissions
    sudo chown -R "${DEPLOY_USER}:${DEPLOY_GROUP}" "${release_path}"
    sudo chmod -R 755 "${release_path}"

    # If Laravel, run artisan tasks with safety: migrations optional via ENV var
    if [[ "${IS_LARAVEL}" == "true" ]] && [[ -f "${release_path}/${ARTISAN}" ]]; then
        # Prepare storage permissions
        if [[ -d "${release_path}/storage" ]]; then
            sudo chown -R "${DEPLOY_USER}:${DEPLOY_GROUP}" "${release_path}/storage"
            sudo chmod -R ug+rwX "${release_path}/storage"
        fi

        # Run artisan commands as deploy user
        log_info "Running Laravel optimize commands..."
        sudo -u "${DEPLOY_USER}" "${PHP_BIN}" "${release_path}/${ARTISAN}" config:cache >/dev/null 2>&1 || log_warning "config:cache failed"
        sudo -u "${DEPLOY_USER}" "${PHP_BIN}" "${release_path}/${ARTISAN}" route:cache >/dev/null 2>&1 || log_warning "route:cache failed"
        sudo -u "${DEPLOY_USER}" "${PHP_BIN}" "${release_path}/${ARTISAN}" view:cache >/dev/null 2>&1 || true

        # Optional: run migrations if allowed
        if [[ "${RUN_MIGRATIONS:-false}" == "true" ]]; then
            log_info "Running database migrations (RUN_MIGRATIONS=true)"
            sudo -u "${DEPLOY_USER}" "${PHP_BIN}" "${release_path}/${ARTISAN}" migrate --force || {
                log_warning "Migrations failed; please investigate (release kept)"
            }
        fi
    fi

    # Atomic symlink swap - point current to new release
    log_info "Swapping symlink to new release..."
    # Create parent for symlink if not exist
    sudo mkdir -p "${CURRENT_DIR}"
    sudo chown "${DEPLOY_USER}:${DEPLOY_GROUP}" "${CURRENT_DIR}"
    ln -sfn "${release_path}" "${CURRENT_DIR}"

    # If Laravel and public dir exists, make sure public/storage symlink points to shared storage
    if [[ "${IS_LARAVEL}" == "true" ]] && [[ -d "${SHARED_DIR}/storage" ]]; then
        # ensure public/storage points to shared storage (inside current)
        if [[ -d "${CURRENT_DIR}/public" ]]; then
            sudo -u "${DEPLOY_USER}" rm -f "${CURRENT_DIR}/public/storage" || true
            sudo -u "${DEPLOY_USER}" ln -sfn "${SHARED_DIR}/storage" "${CURRENT_DIR}/public/storage" || true
        fi
    fi

    # Cleanup old releases
    cd "${RELEASES_DIR}"
    ls -dt */ 2>/dev/null | tail -n +$((KEEP_RELEASES + 1)) | xargs -r rm -rf || true

    log_success "Swapped to version: $(basename "${release_path}")"
}

print_summary() {
    log_section "🎉 Deployment Summary"
    echo -e "${GREEN}App:       ${PROJECT_NAME}${NC}"
    echo -e "${GREEN}URL:       http${SSL_ENABLED:+'s'}://${DOMAIN}${NC}"
    echo -e "${GREEN}Path:      ${CURRENT_DIR}${NC}"
    echo -e "${GREEN}Releases:  ${RELEASES_DIR}${NC}"
    echo -e "${GREEN}Status:    LIVE${NC}"
    echo ""
}

#==============================================================================
# USAGE / ROLLING BACK
#==============================================================================
print_usage() {
    cat <<EOF
Usage: $0 [deploy|rollback <release_timestamp>]

Commands:
  deploy                   Clone, build, and deploy latest ${GIT_BRANCH} from ${GIT_REPO}
  rollback <timestamp>     Rollback 'current' symlink to an existing release directory named by timestamp (e.g. 20230101_123456)
ENV VARS accepted:
  RUN_MIGRATIONS=true      Run database migrations during deploy
  IS_LARAVEL=false         Disable Laravel-specific tasks
  SSL_ENABLED=true         Enable certbot/Let's Encrypt
EOF
}

rollback_release() {
    local target="$1"
    if [[ -z "${target}" ]]; then
        log_error "rollback requires a release timestamp (see ls ${RELEASES_DIR})"
    fi
    local release_path="${RELEASES_DIR}/${target}"
    if [[ ! -d "${release_path}" ]]; then
        log_error "Specified release does not exist: ${release_path}"
    fi

    log_section "⏪ Rolling back to ${target}"
    ln -sfn "${release_path}" "${CURRENT_DIR}"
    sudo systemctl reload nginx || true
    log_success "Rolled back to ${target}"
    print_summary
}

#==============================================================================
# MAIN EXECUTION
#==============================================================================
main_deploy() {
    validate_config
    install_dependencies
    setup_directories

    local new_release
    new_release="$(clone_and_prepare)"
    configure_nginx
    finalize_deploy "${new_release}"
    setup_ssl
    print_summary
}

# Entry point
if [[ "${#}" -lt 1 ]]; then
    print_usage
    exit 1
fi

case "$1" in
    deploy)
        main_deploy
        ;;
    rollback)
        rollback_release "${2:-}"
        ;;
    *)
        print_usage
        exit 1
        ;;
esac

