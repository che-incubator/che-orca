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

FROM registry.access.redhat.com/ubi9/nodejs-22

USER 0

RUN dnf upgrade -y --disablerepo='*' --enablerepo='ubi-*' && \
    dnf install -y --disablerepo='*' --enablerepo='ubi-*' git && \
    dnf clean all

RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "aarch64" ]; then GCLOUD_ARCH="arm"; else GCLOUD_ARCH="x86_64"; fi && \
    curl -fsSL "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-${GCLOUD_ARCH}.tar.gz" \
      | tar -xz -C /usr/lib

# Keep installer-created state out of the image so the entrypoint can link it to /projects.
ARG OPENCODE_VERSION=1.18.34
RUN npm install -g "opencode-ai@${OPENCODE_VERSION}" && \
    rm -rf /opt/app-root/src/.config/opencode \
           /opt/app-root/src/.local/share/opencode \
           /opt/app-root/src/.local/state/opencode

COPY --from=builder /src/orca/out/orcad /opt/orca/runtime
COPY --from=builder /src/orca/out/web /opt/orca/web
COPY --from=builder /src/orca/LICENSE /opt/orca/LICENSE
COPY shared/runtime.sh /usr/local/bin/shared-runtime.sh
COPY shared/bashrc.sh /usr/local/bin/shared-bashrc.sh
COPY shared/discover-models.sh /usr/local/bin/shared-discover-models.sh
COPY entrypoint.sh /usr/local/bin/orca-entrypoint.sh
COPY entrypoint-init-container.sh /entrypoint-init-container.sh

RUN chgrp -R 0 /opt/app-root /opt/orca && \
    chmod -R g=u /opt/app-root /opt/orca && \
    chmod g=u /etc/passwd

USER 1001

CMD ["/orca/entrypoint.sh"]
