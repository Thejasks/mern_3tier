# syntax=docker/dockerfile:1
# ----------------------------------------------------------------------------
# Production image for the Express API (backend tier)
# ----------------------------------------------------------------------------
FROM node:20-slim

ENV NODE_ENV=production

WORKDIR /app

# Install production dependencies first so this layer is cached across code-only
# changes. --omit=dev keeps build tools and test deps out of the runtime image.
COPY package*.json ./
RUN npm install --omit=dev && npm cache clean --force

# Copy application source
COPY src/ ./src/

# Run as an unprivileged user (never run app containers as root in production)
RUN groupadd --system app && useradd --system --gid app app \
    && chown -R app:app /app
USER app

EXPOSE 3000

# Liveness/readiness are handled by Kubernetes probes (/healthz), not Docker.
CMD ["node", "src/index.js"]
