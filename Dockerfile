FROM node:22-slim AS base

# Install bash & curl for entrypoint script compatibility, graphicsmagick for pdf2pic, and vips-dev & build-base for sharp 
RUN apt-get update && apt-get install -y bash curl graphicsmagick libvips-dev build-essential

# All deps stage
FROM base AS deps
WORKDIR /app
ADD admin/package.json admin/package-lock.json ./
RUN npm ci

# Production only deps stage
FROM base AS production-deps
WORKDIR /app
ADD admin/package.json admin/package-lock.json ./
RUN npm ci --omit=dev

# Build stage
FROM base AS build
WORKDIR /app
COPY --from=deps /app/node_modules /app/node_modules
ADD admin/ ./
RUN if [ -f build/ace.js ]; then \
      echo "Using bundled prebuilt admin runtime"; \
    else \
      node ace build; \
    fi

# Production stage
FROM base
ARG VERSION=dev
ARG BUILD_DATE
ARG VCS_REF

# Labels
LABEL org.opencontainers.image.title="RoachNet" \
      org.opencontainers.image.description="The RoachNet official Docker image" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.vendor="RoachWares" \
      org.opencontainers.image.documentation="https://github.com/RoachWares/RoachNet/blob/main/README.md" \
      org.opencontainers.image.source="https://github.com/RoachWares/RoachNet" \
      org.opencontainers.image.licenses="Apache-2.0"

ENV NODE_ENV=production
WORKDIR /app
COPY --from=production-deps /app/node_modules /app/node_modules
COPY --from=build /app/build /app
# Copy root package.json for version info
COPY package.json /app/version.json

# Copy docs and README for access within the container
COPY admin/docs /app/docs
COPY README.md /app/README.md

# Copy entrypoint script and ensure it's executable
COPY install/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
