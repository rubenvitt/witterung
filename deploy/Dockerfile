# syntax=docker/dockerfile:1.7
#
# Witterung container image, linux/amd64 and linux/arm64.
# Adapted from zunder: Rust is cross-compiled on the build platform (QEMU only
# runs the tiny runtime stage), cargo-chef caches the dependencies.
#
# Build (from the repository root):
#   docker build -f deploy/Dockerfile -t witterung .
#   docker buildx build -f deploy/Dockerfile --platform linux/amd64,linux/arm64 -t witterung .

ARG RUST_VERSION=1.97
ARG DEBIAN_RELEASE=bookworm

FROM --platform=$BUILDPLATFORM rust:${RUST_VERSION}-${DEBIAN_RELEASE} AS chef
RUN cargo install cargo-chef --locked --version 0.1.78
WORKDIR /src
ENV CARGO_PROFILE_RELEASE_STRIP=symbols \
    CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc \
    CC_aarch64_unknown_linux_gnu=aarch64-linux-gnu-gcc \
    AR_aarch64_unknown_linux_gnu=aarch64-linux-gnu-ar \
    CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=x86_64-linux-gnu-gcc \
    CC_x86_64_unknown_linux_gnu=x86_64-linux-gnu-gcc \
    AR_x86_64_unknown_linux_gnu=x86_64-linux-gnu-ar

FROM chef AS planner
COPY server/ ./
RUN cargo chef prepare --recipe-path recipe.json

FROM chef AS builder
ARG TARGETARCH
# rusqlite bundles SQLite and needs a C compiler for the target.
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) target=x86_64-unknown-linux-gnu;  cross="gcc-x86-64-linux-gnu libc6-dev-amd64-cross" ;; \
      arm64) target=aarch64-unknown-linux-gnu; cross="gcc-aarch64-linux-gnu libc6-dev-arm64-cross" ;; \
      *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    if [ "$(dpkg --print-architecture)" != "$TARGETARCH" ]; then \
      apt-get update; \
      apt-get install -y --no-install-recommends $cross; \
      rm -rf /var/lib/apt/lists/*; \
    fi; \
    rustup target add "$target"; \
    echo "$target" > /rust-target
COPY --from=planner /src/recipe.json recipe.json
RUN cargo chef cook --release --locked --target "$(cat /rust-target)" --recipe-path recipe.json
COPY server/ ./
RUN set -eux; \
    target="$(cat /rust-target)"; \
    cargo build --release --locked --target "$target" --bin witterung; \
    mkdir -p /out; \
    cp "target/$target/release/witterung" /out/

FROM debian:${DEBIAN_RELEASE}-slim AS runtime
# ca-certificates: outgoing HTTPS (Pocket ID, weather sources)
# sqlite3:         manual backups and inspection
# tini:            PID 1, forwards SIGTERM
# tzdata:          Europe/Berlin
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates sqlite3 tini tzdata; \
    rm -rf /var/lib/apt/lists/*; \
    groupadd --system --gid 10001 witterung; \
    useradd --system --uid 10001 --gid witterung --home-dir /data --no-create-home \
      --shell /usr/sbin/nologin witterung; \
    mkdir -p /data; \
    chown witterung:witterung /data
COPY --from=builder /out/witterung /usr/local/bin/
ENV WITTERUNG_BIND=0.0.0.0:8080 \
    WITTERUNG_DATA_DIR=/data \
    TZ=Europe/Berlin
USER witterung
WORKDIR /data
VOLUME ["/data"]
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --start-interval=2s --retries=3 \
  CMD ["witterung", "healthcheck"]
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["witterung"]
