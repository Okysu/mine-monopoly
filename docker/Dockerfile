# syntax=docker/dockerfile:1.7
#
# Mine Monopoly 服务端镜像（含 Admin 管理面板）
#
#   docker build -f docker/Dockerfile -t monopoly-server .
#
# 构建产物同时包含：
#   - API 服务        SERVER_PORT        (默认 8081)
#   - ICE/PeerJS 服务 ICE_SERVER_PORT    (默认 8082)
#   - Admin 管理面板  MONOPOLY_ADMIN_PORT(默认 8083)

# ==================== Build Stage ====================
FROM node:20-alpine AS builder

ARG PNPM_VERSION=10.10.0

RUN corepack enable && corepack prepare pnpm@${PNPM_VERSION} --activate

WORKDIR /app

# Copy only package.json files for dependency installation
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY packages/env/package.json ./packages/env/
COPY packages/types/package.json ./packages/types/
COPY apps/server/package.json ./apps/server/

RUN pnpm install --frozen-lockfile

# Build @mine-monopoly/env (only workspace package that needs compilation)
COPY packages/env/ ./packages/env/
RUN pnpm --filter @mine-monopoly/env build

# Copy remaining source code
COPY packages/types/ ./packages/types/
COPY apps/server/ ./apps/server/

# apps/server/public 是运行时上传目录，仓库里并不存在（.gitignore 之外的运行时数据）。
# 这里必须先创建出来，否则下面 runtime 阶段的 COPY 会直接失败。
RUN mkdir -p /app/apps/server/public/logs/game \
             /app/apps/server/public/logs/server \
             /app/apps/server/public/temp

# Create standalone deployment with all dependencies properly resolved
# (including transitive deps of workspace packages like dotenv from @mine-monopoly/env)
RUN pnpm --filter @mine-monopoly/server deploy --legacy /app/deploy

# Bundle server with esbuild into a single file
# --packages=external: keep npm dependencies external (loaded from node_modules)
# This preserves CJS/ESM interop for packages like typeorm and dotenv
RUN npm install -g esbuild && \
    npx esbuild /app/deploy/app.ts \
  --bundle --platform=node --format=esm \
  --packages=external \
  --outfile=/app/deploy/server.js

# Build admin frontend (separate install to avoid pulling in client-only deps into server deploy)
# Admin build-time env vars — pass via --build-arg or docker-compose build args
#
# 注意：Admin 面板在运行时会通过服务端注入的 /env.js（window.__RUNTIME_ENV__）读取这些变量，
# 且运行时值优先于构建时值。因此**不要**把真实密钥当 build-arg 传进来（build-arg 会留在镜像层里）。
ARG MAP_ENCRYPT_KEY
ARG PROTOCOL
ARG MONOPOLY_DOMAIN
ARG SERVER_PORT
ARG API_BASE_PREFIX
ARG ADMIN_BASE_PREFIX
ENV MAP_ENCRYPT_KEY=${MAP_ENCRYPT_KEY} \
    PROTOCOL=${PROTOCOL} \
    MONOPOLY_DOMAIN=${MONOPOLY_DOMAIN} \
    SERVER_PORT=${SERVER_PORT} \
    API_BASE_PREFIX=${API_BASE_PREFIX} \
    ADMIN_BASE_PREFIX=${ADMIN_BASE_PREFIX}

COPY packages/utils/package.json ./packages/utils/
COPY apps/admin/package.json ./apps/admin/
RUN pnpm install --frozen-lockfile

COPY packages/utils/ ./packages/utils/
COPY apps/admin/ ./apps/admin/
RUN pnpm --filter @mine-monopoly/admin build

# ==================== Runtime Stage ====================
FROM node:20-alpine

ARG VERSION=dev
ARG REVISION=unknown
ARG SOURCE_URL=https://github.com/Okysu/mine-monopoly

LABEL org.opencontainers.image.title="mine-monopoly-server" \
      org.opencontainers.image.description="Mine Monopoly 服务端（API + ICE + Admin 面板）" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.licenses="GPL-3.0"

WORKDIR /app

ENV NODE_ENV=production \
    SERVER_PORT=8081 \
    ICE_SERVER_PORT=8082 \
    MONOPOLY_ADMIN_PORT=8083

# Copy deployed node_modules (self-contained, all deps properly resolved)
COPY --from=builder /app/deploy/node_modules ./node_modules

# Copy bundled output
COPY --from=builder /app/deploy/server.js ./server.js

# Copy public files (static assets: avatars, game maps, logs)
COPY --from=builder /app/apps/server/public ./public

# Copy admin frontend build output
COPY --from=builder /app/apps/admin/dist ./admin-dist

# 运行时的上传/日志目录（挂载持久化卷后依然需要存在）
RUN mkdir -p /app/public/logs/game /app/public/logs/server /app/public/temp

COPY docker/entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 8081 8082 8083

# /health 由 Express 提供；容器启动初期 DB 还没连上时 healthcheck 会失败，
# 因此给了较长的 start-period。
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=5 \
    CMD wget -q -O- "http://127.0.0.1:${SERVER_PORT}/health" >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["node", "server.js"]
