#!/bin/bash

set -e

echo "==============================================="
echo "🚀 Deploying JSP App at jsp.morphsync.com"
echo "==============================================="

# ========= CONFIG =========
DOMAIN="jsp.morphsync.com"                     # Change if needed
INSTALL_DIR="/var/www/morphsync.com/${DOMAIN}" # For storing app files/logs locally

APP_NAME="myjspapp"                            # Context path -> http://DOMAIN/myjspapp/
WAR_SOURCE="/home/$USER/build/${APP_NAME}.war" # Path to your built WAR file

TOMCAT_SERVICE="tomcat9"
TOMCAT_WEBAPPS_DIR="/var/lib/tomcat9/webapps"

# ========= UPDATE SYSTEM =========
sudo apt update && sudo apt upgrade -y
sudo apt install -y openjdk-17-jdk tomcat9 tomcat9-admin nginx

sudo systemctl enable ${TOMCAT_SERVICE}
sudo systemctl start ${TOMCAT_SERVICE}

sudo systemctl enable nginx
sudo systemctl start nginx

# ========= PREPARE INSTALL DIR =========
sudo mkdir -p "${INSTALL_DIR}"
sudo chown -R $USER:$USER "${INSTALL_DIR}"

echo "📁 Using INSTALL_DIR = ${INSTALL_DIR}"

# ========= DEPLOY WAR TO TOMCAT =========
if [ ! -f "${WAR_SOURCE}" ]; then
  echo "❌ WAR file not found at: ${WAR_SOURCE}"
  echo "Please build your WAR and update WAR_SOURCE path in this script."
  exit 1
fi

echo "📦 Copying WAR to Tomcat webapps..."
sudo cp "${WAR_SOURCE}" "${TOMCAT_WEBAPPS_DIR}/${APP_NAME}.war"
sudo chown tomcat:tomcat "${TOMCAT_WEBAPPS_DIR}/${APP_NAME}.war"

echo "🔁 Restarting Tomcat to reload application..."
sudo systemctl restart ${TOMCAT_SERVICE}

# ========= WAIT FOR TOMCAT TO DEPLOY =========
echo "⏳ Waiting 15 seconds for Tomcat to deploy the WAR..."
sleep 15

# ========= NGINX REVERSE PROXY =========
sudo mkdir -p /etc/nginx/sites-available/morphsync.com

NGX_AVAIL="/etc/nginx/sites-available/morphsync.com/${DOMAIN}.conf"
NGX_ENABLED="/etc/nginx/sites-enabled/${DOMAIN}"

if [ ! -f "${NGX_AVAIL}" ]; then
  echo "📝 Creating Nginx config at ${NGX_AVAIL}..."

  sudo tee "${NGX_AVAIL}" >/dev/null <<NGINX
server {
    listen 80;
    server_name ${DOMAIN};

    access_log /var/log/nginx/${DOMAIN}_access.log;
    error_log  /var/log/nginx/${DOMAIN}_error.log;

    location / {
        proxy_pass http://127.0.0.1:8080/${APP_NAME}/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }
}
NGINX

  sudo ln -s "${NGX_AVAIL}" "${NGX_ENABLED}" || true
fi

echo "🔍 Testing Nginx configuration..."
sudo nginx -t

echo "🔁 Reloading Nginx..."
sudo systemctl reload nginx

# ========= STATUS SUMMARY =========
echo "===================================================="
echo "✅ JSP Application deployed!"
echo "App Name      : ${APP_NAME}"
echo "WAR Source    : ${WAR_SOURCE}"
echo "Tomcat Dir    : ${TOMCAT_WEBAPPS_DIR}/${APP_NAME}.war"
echo "Tomcat Port   : 8080"
echo "Internal URL  : http://127.0.0.1:8080/${APP_NAME}/"
echo "Public URL    : http://${DOMAIN}/"
echo "Nginx Conf    : ${NGX_AVAIL}"
echo "Logs (Nginx)  : /var/log/nginx/${DOMAIN}_access.log"
echo "               /var/log/nginx/${DOMAIN}_error.log"
echo "Logs (Tomcat) : /var/log/tomcat9/"
echo "===================================================="
