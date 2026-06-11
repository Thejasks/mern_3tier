# syntax=docker/dockerfile:1
# ----------------------------------------------------------------------------
# Multi-stage build for the React SPA (frontend tier).
#
# Stage 1 compiles the static bundle. Stage 2 serves it with nginx.
# The backend URL is NOT baked in at build time — it is injected at container
# start from the BACKEND_URL env var (see docker-entrypoint.sh). This lets the
# SAME image be promoted dev -> prod, which is the GitOps-friendly pattern.
# ----------------------------------------------------------------------------

# ---- Build stage ----
FROM node:20-slim AS build
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .
RUN npm run build

# ---- Runtime stage ----
FROM nginx:1.27-alpine

# SPA routing + listen on 3000 to match the Kubernetes Service targetPort
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/build /usr/share/nginx/html

# Entrypoint writes /usr/share/nginx/html/env-config.js from $BACKEND_URL at start
COPY docker-entrypoint.sh /docker-entrypoint.d/40-env-config.sh
RUN chmod +x /docker-entrypoint.d/40-env-config.sh

EXPOSE 3000
# nginx:alpine base image already sets CMD ["nginx", "-g", "daemon off;"]
