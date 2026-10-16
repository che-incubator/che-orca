# Run build tools on the host architecture to avoid amd64 emulation failures.
FROM --platform=$BUILDPLATFORM registry.access.redhat.com/ubi9/nodejs-24 AS builder

USER 0

RUN dnf install -y --disablerepo='*' --enablerepo='ubi-*' patch unzip && \
    dnf clean all && \
    npm install -g pnpm@12.0.0

# Pin the source so the standalone runtime and web client use the same protocol.
ENV ORCA_VERSION=1.4.219
WORKDIR /src/orca
RUN curl -fsSL "https://github.com/stablyai/orca/archive/refs/tags/v${ORCA_VERSION}.tar.gz" \
      | tar -xz --strip-components=1

# Wire in the web root and initialize the standalone terminal graph.
COPY web-client.patch /tmp/web-client.patch
RUN patch -p1 < /tmp/web-client.patch

# Build the standalone runtime without downloading or rebuilding Electron.
RUN NODE_ENV=development pnpm install --frozen-lockfile --ignore-scripts && \
    pnpm rebuild esbuild

# Run scripts directly so pnpm does not reinstall skipped Electron dependencies.
ARG TARGETARCH
RUN case "$TARGETARCH" in \
      amd64) ORCAD_ARCH=x64 ;; \
      arm64) ORCAD_ARCH=arm64 ;; \
      *) echo "Unsupported Orca architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac && \
    node config/scripts/build-orcad-bun.mjs --target "linux-${ORCAD_ARCH}-glibc" && \
    node --run build:web

# Package the CLI with the runtime dependencies upstream ships beside its desktop CLI,
# so orcad's Bun runtime can run it.
RUN case "$TARGETARCH" in \
      amd64) ORCAD_ARCH=x64 ;; \
      arm64) ORCAD_ARCH=arm64 ;; \
    esac && \
    node node_modules/typescript/bin/tsc -p config/tsconfig.cli.json --outDir out --composite false --incremental false && \
    node config/scripts/verify-cli-bin.mjs --fix-executable --fix-package-json && \
    mkdir -p /opt/orca-cli && \
    cp -r out/cli out/main out/shared out/package.json /opt/orca-cli/ && \
    node -e ' \
      const { cpSync } = require("node:fs"); \
      const { join } = require("node:path"); \
      const runtime = require("./config/packaged-runtime-node-modules.cjs"); \
      for (const { from, to } of runtime.createPackagedRuntimeNodeModuleResources("linux")) \
        cpSync(from, join("/opt/orca-cli", to), { recursive: true, dereference: true }); \
      runtime.prunePackagedRuntimeNodeModules("/opt/orca-cli", "linux", process.argv[1]); \
    ' "$ORCAD_ARCH"

FROM registry.access.redhat.com/ubi9/nodejs-22

USER 0

RUN dnf upgrade -y --disablerepo='*' --enablerepo='ubi-*' && \
    dnf install -y --disablerepo='*' --enablerepo='ubi-*' git && \
    dnf clean all

COPY --from=builder /src/orca/out/orcad /opt/orca/runtime
COPY --from=builder /src/orca/out/web /opt/orca/web
COPY --from=builder /src/orca/LICENSE /opt/orca/LICENSE
COPY --from=builder /opt/orca-cli /opt/orca/cli
COPY orca.sh /opt/orca/bin/orca
COPY shared/runtime.sh /usr/local/bin/shared-runtime.sh
COPY shared/bashrc.sh /usr/local/bin/shared-bashrc.sh
COPY entrypoint.sh /usr/local/bin/orca-entrypoint.sh
COPY entrypoint-init-container.sh /entrypoint-init-container.sh

RUN chgrp -R 0 /opt/app-root /opt/orca && \
    chmod -R g=u /opt/app-root /opt/orca && \
    chmod g=u /etc/passwd

USER 1001

# Idle like the universal developer image. When orca-runtime runs as its own
# container, the postStart command starts /orca/entrypoint.sh.
CMD ["tail", "-f", "/dev/null"]
