# Turbofish: S3-Native Hybrid Search Engine
# Multi-stage minimal production container build

# Stage 1: Build binary using official MoonBit toolchain
FROM ubuntu:24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    build-essential \
    libcurl4-openssl-dev \
    git \
 && rm -rf /var/lib/apt/lists/*

# Install MoonBit toolchain
RUN curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
ENV PATH="/root/.moon/bin:${PATH}"

WORKDIR /app
COPY . .

# Compile optimized native release executable
RUN moon bundle --target native
RUN moon build --target native --release cmd/serve

# Stage 2: Minimal runtime image (< 25MB)
FROM alpine:3.20

RUN apk add --no-cache \
    ca-certificates \
    libcurl \
    libgcc \
    libstdc++ \
    tzdata

WORKDIR /app
COPY --from=builder /app/_build/native/release/build/cmd/serve/serve.exe /app/turbofish-serve

EXPOSE 8080

# Defaults to local fs store; override with SPND_STORE=s3
ENV SPND_STORE=fs:/data
ENV SPND_PORT=8080
VOLUME ["/data"]

ENTRYPOINT ["/app/turbofish-serve"]
