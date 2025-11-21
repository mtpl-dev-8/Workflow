#!/bin/bash

#==============================================================================
# Python Flask Deployment Script
# Description: Zero-downtime deployment for Flask with Gunicorn & Systemd
# Stack: Nginx -> Gunicorn -> Flask (Systemd Managed)
# Author: DevOps Engineer
# Version: 2.0.0
#==============================================================================

# --- SHELL SAFETY ---
set -euo pipefail
IFS=$'\n\t'

#==============================================================================
# CONFIGURATION (Dynamic Defaults)
#==============================================================================
PROJECT_NAME="${PROJECT_NAME:-flask-app}"
DOMAIN="${DOMAIN:-api.example.com}"
GIT_REPO="${GIT_REPO:-}" 
GIT_BRANCH="${GIT_BRANCH:-main}"

# App Settings
APP_PORT="${APP_PORT:-8000}"           
APP_MODULE="${APP_MODULE:-app:app}"    # file:variable (e.g., main.py has 'app = Flask...')
WORKERS="${WORKERS:-3}"                # Gunicorn workers (2 * CPU + 1)

# Paths
BASE_DIR="/var/www"
DOMAIN_DIR="${BASE_DIR}/${DOMAIN}"
INSTALL_DIR="${DOMAIN_DIR}/current"    # Symlink to active release
RELEASES_DIR="${DOMAIN_DIR}/releases"
SHARED_DIR="${DOMAIN_DIR}/shared"
LOG_DIR="${DOMAIN_DIR}/logs"

# Nginx / SSL
NGINX_PORT="${NGINX_PORT:-80}"
SSL_ENABLED="${SSL_ENABLED:-false}"
EMAIL="${EMAIL:-admin@${DOMAIN}}"

# User Config
DEPLOY_USER="${DEPLOY_USER:-$USER}"
DEPLOY_GROUP="${DEPLOY_GROUP:-www-data}"
SHARED_SYMLINKS="${SHARED_SYMLINKS:-.env,instance,db.sqlite3}" 

#==============================================================================
# LOGGING
#==============================================================================
readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
log_success() { echo -e "${GREEN}[✓]${NC} $1" >&2; }
log_error() { echo -e "${RED}[✗]${NC} $1" >&2; exit 1; }

#==============================================================================
# 1. SYSTEM PREP
#==============================================================================
install_dependencies() {
    log_info "📦 Checking System Dependencies..."
    
    local packages=("git" "nginx" "python3-full" "python3-pip" "python3-venv" "acl" "certbot" "python3-certbot-nginx")
    
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}" >/dev/null 2>&1 || true
    
    # Create Directory Structure
    sudo mkdir -p "${BASE_DIR}" "${DOMAIN_DIR}" "${RELEASES_DIR}" "${SHARED_DIR}" "${LOG_DIR}"
    
    # Permission Fixes
    sudo chown -R "${DEPLOY_USER}:${DEPLOY_GROUP}" "${DOMAIN_DIR}"
    sudo chmod -R 775 "${DOMAIN_DIR}" # Group writable
    
    log_success "System ready"
}

#==============================================================================
# 2. CLONE & VIRTUAL ENV
#==============================================================================
setup_release() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local release_path="${RELEASES_DIR}/${timestamp}"
    
    log_info "🏗️  Creating Release: ${timestamp}"
    
    # 1. Clone
    git clone --quiet --depth 1 --branch "${GIT_BRANCH}" "${GIT_REPO}" "${release_path}"
    cd "${release_path}"
    
    # 2. Link Shared Files (DBs, .env, Uploads)
    IFS=',' read -ra LINKS <<< "$SHARED_SYMLINKS"
    for item in "${LINKS[@]}"; do
        local target="${release_path}/${item}"
        local source="${SHARED_DIR}/${item}"
        
        # Remove default file from repo if exists
        rm -rf "$target"
        mkdir -p "$(dirname "$target")"
        
        # If source doesn't exist, create it to prevent breaking
        if [[ "$item" == *.* ]]; then
             [[ ! -f "$source" ]] && touch "$source"
        else
             [[ ! -d "$source" ]] && mkdir -p "$source"
        fi

        ln -sfn "$source" "$target"
    done

    # 3. Setup Python Venv
    log_info "🐍 Setting up Virtual Environment..."
    python3 -m venv venv
    
    # Activate & Install
    source venv/bin/activate
    
    log_info "Installing requirements..."
    pip install --upgrade pip >/dev/null
    pip install gunicorn >/dev/null # Ensure Gunicorn is present
    
    if [[ -f "requirements.txt" ]]; then
        pip install -r requirements.txt >/dev/null
    else
        log_error "requirements.txt not found!"
    fi
    
    # Return the path to main
    echo "${release_path}"
}

#==============================================================================
# 3. SYSTEMD SERVICE (Gunicorn)
#==============================================================================
configure_systemd() {
    local service_name="${PROJECT_NAME}"
    local service_file="/etc/systemd/system/${service_name}.service"
    
    log_info "⚙️  Configuring Systemd Service: ${service_name}"
    
    # Creates a service that points to the 'current' symlink
    # This allows us to restart the service after deployment without changing the service file
    
    sudo tee "${service_file}" > /dev/null <<EOF
[Unit]
Description=Gunicorn instance to serve ${PROJECT_NAME}
After=network.target

[Service]
User=${DEPLOY_USER}
Group=${DEPLOY_GROUP}
WorkingDirectory=${INSTALL_DIR}
Environment="PATH=${INSTALL_DIR}/venv/bin"
ExecStart=${INSTALL_DIR}/venv/bin/gunicorn --workers ${WORKERS} --bind 127.0.0.1:${APP_PORT} ${APP_MODULE}
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable "${service_name}" >/dev/null 2>&1
    
    log_success "Systemd service created"
}

#==============================================================================
# 4. NGINX CONFIGURATION
#==============================================================================
configure_nginx() {
    log_info "🌐 Configuring Nginx Reverse Proxy"
    local config_path="/etc/nginx/sites-available/${DOMAIN}.conf"
    
    sudo tee "${config_path}" > /dev/null <<EOF
server {
    listen ${NGINX_PORT};
    server_name ${DOMAIN} www.${DOMAIN};

    # Logs
    access_log ${LOG_DIR}/nginx_access.log;
    error_log ${LOG_DIR}/nginx_error.log;

    # 1. Serve Static Files Directly (Bypass Python)
    location /static {
        alias ${INSTALL_DIR}/static;
        expires 30d;
    }
    
    # 2. Serve Media/Uploads Directly
    location /media {
        alias ${INSTALL_DIR}/media;
        expires 30d;
    }

    # 3. Pass everything else to Gunicorn
    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

    sudo ln -sf "${config_path}" "/etc/nginx/sites-enabled/${DOMAIN}.conf"
    
    # Check config before reloading
    if sudo nginx -t 2>/dev/null; then
        sudo systemctl reload nginx
    else
        log_error "Nginx config failed check"
    fi
}

#==============================================================================
# 5. DEPLOY & RESTART
#==============================================================================
finalize_deployment() {
    local release_path=$1
    
    log_info "🚀 Finalizing Deployment..."
    
    # 1. Atomic Switch
    ln -sfn "${release_path}" "${INSTALL_DIR}"
    
    # 2. Restart Python App
    sudo systemctl restart "${PROJECT_NAME}"
    
    # 3. Cleanup Old Releases (Keep last 5)
    cd "${RELEASES_DIR}"
    ls -dt */ | tail -n +6 | xargs rm -rf 2>/dev/null || true
    
    # 4. SSL (Optional)
    if [[ "${SSL_ENABLED}" == "true" ]]; then
        sudo certbot --nginx -d "${DOMAIN}" --non-interactive --agree-tos -m "${EMAIL}" --redirect >/dev/null 2>&1 || log_info "SSL cert likely already exists."
    fi
    
    log_success "Deployment Complete!"
    echo -e "${GREEN}App is running at: http://${DOMAIN}${NC}"
}

#==============================================================================
# MAIN
#==============================================================================
main() {
    [[ -z "$GIT_REPO" ]] && log_error "GIT_REPO is required"
    
    install_dependencies
    
    # Clone and Setup Venv
    new_release=$(setup_release)
    
    # Configs
    configure_systemd
    configure_nginx
    
    # Switch
    finalize_deployment "$new_release"
}

main
