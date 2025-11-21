#!/bin/bash

#==============================================================================
# React/Node Application Deployment Script 
# Description: Zero-downtime deployment for React Apps via Nginx
# Author: DevOps Engineer (Optimized by Gemini)
# Version: 7.1.0
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
log_info() { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
log_success() { echo -e "${GREEN}[✓]${NC} $1" >&2; }
log_warning() { echo -e "${YELLOW}[⚠]${NC} $1" >&2; }
log_error() { echo -e "${RED}[✗]${NC} $1" >&2; exit 1; }
log_section() {
    echo "" >&2
    echo -e "${MAGENTA}╔════════════════════════════════════════════════════════╗${NC}" >&2
    echo -e "${MAGENTA}║ $1${NC}" >&2
    echo -e "${MAGENTA}╚════════════════════════════════════════════════════════╝${NC}" >&2
}

#==============================================================================
# CONFIGURATION (Dynamic Defaults)
#==============================================================================
PROJECT_NAME="${PROJECT_NAME:-react-app}"
DOMAIN="${DOMAIN:-weatherappsforu.com}"
GIT_REPO="${GIT_REPO:-https://github.com/Adedoyin-Emmanuel/react-weather-app.git}" # Must be provided
GIT_BRANCH="${GIT_BRANCH:-main}"
ENVIRONMENT="${ENVIRONMENT:-production}"

# Paths
BASE_DIR="/var/www"
DOMAIN_DIR="${BASE_DIR}/${DOMAIN}"
INSTALL_DIR="${DOMAIN_DIR}/current"
RELEASES_DIR="${DOMAIN_DIR}/releases"
SHARED_DIR="${DOMAIN_DIR}/shared"
BACKUP_DIR="${DOMAIN_DIR}/backups"
LOG_DIR="${DOMAIN_DIR}/logs"

# Build & Node
NODE_VERSION="${NODE_VERSION:-20}"
BUILD_OUTPUT_DIR="${BUILD_OUTPUT_DIR:-}" # Auto-detect if empty
PACKAGE_MANAGER="${PACKAGE_MANAGER:-auto}" # npm, yarn, pnpm, or auto

# Nginx / SSL
NGINX_PORT="${NGINX_PORT:-80}"
SSL_ENABLED="${SSL_ENABLED:-false}"
EMAIL="${EMAIL:-admin@${DOMAIN}}"

# Settings
KEEP_RELEASES="${KEEP_RELEASES:-5}"
DEPLOY_USER="${DEPLOY_USER:-$USER}"
DEPLOY_GROUP="${DEPLOY_GROUP:-www-data}"
SHARED_SYMLINKS="${SHARED_SYMLINKS:-.env,public/uploads}" # Comma separated

# System
SERVER_IP=$(hostname -I | awk '{print $1}' || echo "127.0.0.1")

#==============================================================================
# HELPER: LOAD NVM
#==============================================================================
load_nvm() {
    export NVM_DIR="$HOME/.nvm"
    [[ -s "$NVM_DIR/nvm.sh" ]] && \. "$NVM_DIR/nvm.sh"
    
    if ! command -v nvm &> /dev/null; then
        log_warning "NVM not found. Attempting to install..."
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
        [[ -s "$NVM_DIR/nvm.sh" ]] && \. "$NVM_DIR/nvm.sh"
    fi
}

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
    
    # Create User/Group if missing (Basic check)
    if ! getent group "${DEPLOY_GROUP}" >/dev/null; then
        log_warning "Group ${DEPLOY_GROUP} not found. Ensure Nginx user exists."
    fi

    log_info "Target: ${DOMAIN} (${GIT_BRANCH})"
    log_success "Configuration valid"
}

#==============================================================================
# 2. SYSTEM PREP
#==============================================================================
install_dependencies() {
    log_section "📦 System Dependencies"
    
    # Only update if explicitly told to, or if apt cache is very old, to save time
    # sudo apt-get update -qq || true
    
    local packages=("git" "nginx" "certbot" "python3-certbot-nginx" "jq" "acl")
    
    log_info "Ensuring essential packages are installed..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}" >/dev/null 2>&1 || true
    
    systemctl is-active --quiet nginx || sudo systemctl start nginx
    log_success "Dependencies ready"
}

setup_nodejs() {
    log_section "🟢 Node.js Setup (${NODE_VERSION})"
    load_nvm
    
    if ! nvm ls "${NODE_VERSION}" &> /dev/null; then
        log_info "Installing Node ${NODE_VERSION}..."
        nvm install "${NODE_VERSION}" >/dev/null 2>&1
    fi
    nvm use "${NODE_VERSION}" >/dev/null 2>&1
    
    # Ensure global yarn/pnpm if needed
    npm install -g yarn pnpm >/dev/null 2>&1 || true
    
    log_success "Node: $(node -v)"
}

setup_directories() {
    log_section "📁 Directory Structure"
    sudo mkdir -p "${BASE_DIR}" "${DOMAIN_DIR}" "${RELEASES_DIR}" "${SHARED_DIR}" "${BACKUP_DIR}" "${LOG_DIR}"
    
    # Fix permissions for deploy user
    sudo chown -R "${DEPLOY_USER}:${DEPLOY_GROUP}" "${DOMAIN_DIR}"
    sudo chmod -R 775 "${DOMAIN_DIR}"
    
    # Create shared folders
    IFS=',' read -ra DIRS <<< "$SHARED_SYMLINKS"
    for dir in "${DIRS[@]}"; do
        local shared_path="${SHARED_DIR}/${dir}"
        # If it looks like a directory (no extension or ends in slash), make dir
        if [[ "$dir" != *.* ]]; then
            mkdir -p "$shared_path"
        else
            # It's a file, ensure parent dir exists and touch file
            mkdir -p "$(dirname "$shared_path")"
            [[ ! -f "$shared_path" ]] && touch "$shared_path"
        fi
    done
    
    log_success "Directories created at ${DOMAIN_DIR}"
}

#==============================================================================
# 3. BUILD PROCESS
#==============================================================================
clone_and_build() {
    log_section "🏗️ Clone & Build"
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local release_path="${RELEASES_DIR}/${timestamp}"
    
    # 1. Clone
    log_info "Cloning ${GIT_REPO}..."
    git clone --quiet --depth 1 --branch "${GIT_BRANCH}" "${GIT_REPO}" "${release_path}"
    cd "${release_path}"
    
    # 2. Link Shared Items
    IFS=',' read -ra LINKS <<< "$SHARED_SYMLINKS"
    for item in "${LINKS[@]}"; do
        local target="${release_path}/${item}"
        local source="${SHARED_DIR}/${item}"
        
        # Clean default file from repo if exists
        rm -rf "$target"
        
        # Ensure parent directory exists in release
        mkdir -p "$(dirname "$target")"
        
        # Link
        ln -sfn "$source" "$target"
        log_debug "Linked shared item: $item"
    done
    
    # 3. Install Deps
    load_nvm
    log_info "Installing dependencies..."
    if [[ -f "yarn.lock" ]]; then
        yarn install --frozen-lockfile >/dev/null 2>&1
        cmd="yarn"
    elif [[ -f "pnpm-lock.yaml" ]]; then
        pnpm install --frozen-lockfile >/dev/null 2>&1
        cmd="pnpm"
    else
        npm ci --legacy-peer-deps >/dev/null 2>&1
        cmd="npm"
    fi
    
    # 4. Build
    log_info "Building application ($cmd run build)..."
    # Try common build scripts
    if grep -q "\"build:${ENVIRONMENT}\"" package.json; then
        $cmd run "build:${ENVIRONMENT}" >/dev/null
    elif grep -q "\"build\"" package.json; then
        $cmd run build >/dev/null
    else
        log_error "No build script found in package.json"
    fi
    
    # 5. Detect Output
    if [[ -z "$BUILD_OUTPUT_DIR" ]]; then
        if [[ -d "dist" ]]; then BUILD_OUTPUT_DIR="dist"; 
        elif [[ -d "build" ]]; then BUILD_OUTPUT_DIR="build";
        else log_error "Could not auto-detect build output (dist/build)."; fi
    fi
    
    # Verify Index
    if [[ ! -f "${release_path}/${BUILD_OUTPUT_DIR}/index.html" ]]; then
        log_error "Build failed: index.html not found in ${BUILD_OUTPUT_DIR}"
    fi
    
    # Export for next steps
    echo "${release_path}"
}

#==============================================================================
# 4. NGINX CONFIGURATION
#==============================================================================
configure_nginx() {
    log_section "🌐 Nginx Configuration"
    local config_path="/etc/nginx/sites-available/${DOMAIN}.conf"
    
    # Write Config
    sudo tee "${config_path}" > /dev/null <<EOF
server {
    listen ${NGINX_PORT};
    server_name ${DOMAIN} www.${DOMAIN};
    root ${INSTALL_DIR}; # Points to symlink
    index index.html;

    # Logs
    access_log ${LOG_DIR}/nginx_access.log;
    error_log ${LOG_DIR}/nginx_error.log warn;

    # Security Headers
    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Content-Type-Options "nosniff";

    # Gzip
    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;

    # SPA Routing
    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # Cache Static Assets
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)$ {
        expires 1y;
        add_header Cache-Control "public, no-transform";
    }
}
EOF

    # Enable Site
    sudo ln -sf "${config_path}" "/etc/nginx/sites-enabled/${DOMAIN}.conf"
    
    # Test & Reload
    if sudo nginx -t 2>/dev/null; then
        sudo systemctl reload nginx
        log_success "Nginx configured and reloaded"
    else
        log_error "Nginx config test failed"
    fi
}

setup_ssl() {
    if [[ "${SSL_ENABLED}" == "true" ]]; then
        log_section "🔒 SSL Configuration (Certbot)"
        # Check if cert already exists to avoid rate limits
        if ! sudo certbot certificates | grep -q "${DOMAIN}"; then
            sudo certbot --nginx -d "${DOMAIN}" -d "www.${DOMAIN}" \
                --non-interactive --agree-tos -m "${EMAIL}" --redirect
            log_success "SSL Certificate installed"
        else
            log_info "SSL Certificate already exists"
        fi
    fi
}

#==============================================================================
# 5. DEPLOY (ATOMIC SWAP)
#==============================================================================
deploy_release() {
    local release_path=$1
    log_section "🚀 Finalizing Deployment"
    
    local build_path="${release_path}/${BUILD_OUTPUT_DIR}"
    
    # Validate permissions before switch
    sudo chmod -R 755 "${release_path}"
    
    # Atomic Symlink Swap
    log_info "Switching symlink to new release..."
    ln -sfn "${build_path}" "${INSTALL_DIR}"
    
    # Cleanup
    cd "${RELEASES_DIR}"
    ls -dt */ | tail -n +$((KEEP_RELEASES + 1)) | xargs rm -rf 2>/dev/null || true
    
    log_success "Swapped to version: $(basename "$release_path")"
}

print_summary() {
    log_section "🎉 Deployment Summary"
    echo -e "${GREEN}App:       ${PROJECT_NAME}${NC}"
    echo -e "${GREEN}URL:       http${SSL_ENABLED:+'s'}://${DOMAIN}${NC}"
    echo -e "${GREEN}Path:      ${INSTALL_DIR}${NC}"
    echo -e "${GREEN}Status:    LIVE${NC}"
    echo ""
}

#==============================================================================
# MAIN EXECUTION
#==============================================================================
main() {
    validate_config
    install_dependencies
    setup_nodejs
    setup_directories
    
    # Run build and capture the path
    local new_release
    new_release=$(clone_and_build)
    
    configure_nginx
    deploy_release "$new_release"
    setup_ssl
    
    print_summary
}

# Run Main
main
