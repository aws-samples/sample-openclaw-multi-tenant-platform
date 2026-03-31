# Stage 1: Build
FROM --platform=$BUILDPLATFORM rust:1.94-bookworm AS builder
ARG TARGETPLATFORM
ARG BUILDPLATFORM
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*
# Install cross-compilation toolchain if needed
RUN case "$TARGETPLATFORM" in \
      "linux/arm64") apt-get update && apt-get install -y --no-install-recommends gcc-aarch64-linux-gnu libc6-dev-arm64-cross && \
        rustup target add aarch64-unknown-linux-gnu && rm -rf /var/lib/apt/lists/* ;; \
      "linux/amd64") apt-get update && apt-get install -y --no-install-recommends gcc libc6-dev && rm -rf /var/lib/apt/lists/* ;; \
    esac
COPY Cargo.toml Cargo.lock ./
COPY src/ src/
RUN case "$TARGETPLATFORM" in \
      "linux/arm64") \
        export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc && \
        export PKG_CONFIG_SYSROOT_DIR=/usr/aarch64-linux-gnu && \
        cargo build --release --target aarch64-unknown-linux-gnu --bin tenant-operator && \
        cp target/aarch64-unknown-linux-gnu/release/tenant-operator target/release/tenant-operator ;; \
      *) cargo build --release --bin tenant-operator ;; \
    esac

# Stage 2: Runtime (distroless -- minimal attack surface, multi-arch)
FROM gcr.io/distroless/cc-debian12
LABEL org.opencontainers.image.source="https://github.com/snese/sample-openclaw-multi-tenant-platform"
LABEL org.opencontainers.image.description="OpenClaw Tenant Operator -- manages tenant lifecycle on EKS"
LABEL org.opencontainers.image.licenses="MIT"
COPY --from=builder /app/target/release/tenant-operator /
EXPOSE 8080
# checkov:skip=CKV_DOCKER_2: K8s liveness/readiness probes handle health checks; distroless has no shell for HEALTHCHECK
USER nonroot
ENTRYPOINT ["/tenant-operator"]
