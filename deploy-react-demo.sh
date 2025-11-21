#!/bin/bash

# 1. Project Details
export PROJECT_NAME="react-weather-app"
export DOMAIN="weather.yourdomain.com"  # <--- CHANGE THIS
export GIT_REPO="https://github.com/Adedoyin-Emmanuel/react-weather-app.git"
export GIT_BRANCH="master"              # The repo uses 'master', not 'main'

# 2. Build Details
export PACKAGE_MANAGER="npm"            # This repo uses package-lock.json
export BUILD_OUTPUT_DIR="build"         # Create-React-App outputs to 'build' folder

# 3. SSL & Server
export SSL_ENABLED="true"
export EMAIL="your-email@example.com"   # <--- CHANGE THIS

# 4. SHARED FILES (Crucial for Weather Apps)
# We need to link the .env file so the build can see the API keys
export SHARED_SYMLINKS=".env"

# 5. Execute the Main Script
/usr/local/bin/react-deploy
