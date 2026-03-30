# Stage 1: Build
FROM rust:1.94-slim AS builder
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*
COPY Cargo.toml Cargo.lock ./
COPY src/ src/
RUN cargo build --release --bin tenant-operator

# Stage 2: Runtime (distroless — minimal attack surface)
FROM gcr.io/distroless/cc-debian12
COPY --from=builder /app/target/release/tenant-operator /
EXPOSE 8080
USER nonroot
ENTRYPOINT ["/tenant-operator"]
