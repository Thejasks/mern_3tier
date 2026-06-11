#!/bin/sh
# Generate the runtime config consumed by the SPA (window._env_).
# Run automatically by the nginx base image via /docker-entrypoint.d/.
# BACKEND_URL is supplied by the Kubernetes Deployment (per environment).
set -eu

: "${BACKEND_URL:=https://backend.acadcart.com}"

cat > /usr/share/nginx/html/env-config.js <<EOF
window._env_ = {
  BACKEND_URL: "${BACKEND_URL}"
};
EOF

echo "[entrypoint] env-config.js generated with BACKEND_URL=${BACKEND_URL}"
