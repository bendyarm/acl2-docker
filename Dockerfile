# syntax=docker/dockerfile:1
#
# Multi-platform Dockerfile for ACL2 on SBCL
# Builds for linux/amd64 and linux/arm64
#
# Build arguments:
#   SBCL_VERSION - SBCL version to build (default: 2.6.1)
#   ACL2_COMMIT  - ACL2 commit/tag/branch to build (default: master)

ARG SBCL_VERSION=2.6.1

# =============================================================================
# Stage 1: Build SBCL from source
# =============================================================================
FROM ubuntu:24.04 AS sbcl-builder

ARG SBCL_VERSION

# Install bootstrap SBCL from apt (works for both amd64 and arm64)
# plus build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    ca-certificates \
    zlib1g-dev \
    bzip2 \
    sbcl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Download SBCL source and verify checksum
# SHA256 computed from SourceForge download on 2025-02-04
RUN curl -fsSL "https://downloads.sourceforge.net/project/sbcl/sbcl/${SBCL_VERSION}/sbcl-${SBCL_VERSION}-source.tar.bz2" \
    -o sbcl-source.tar.bz2 \
    && echo "5f2cd5bb7d3e6d9149a59c05acd8429b3be1849211769e5a37451d001e196d7f  sbcl-source.tar.bz2" | sha256sum -c - \
    && tar xjf sbcl-source.tar.bz2 \
    && rm sbcl-source.tar.bz2

# Build SBCL with ACL2-recommended switches
# See ACL2 xdoc topic SBCL-INSTALLATION for details
WORKDIR /build/sbcl-${SBCL_VERSION}
RUN sh make.sh \
      --without-immobile-space \
      --without-immobile-code \
      --without-compact-instance-header \
      --prefix=/usr/local

RUN sh install.sh

# =============================================================================
# Stage 2: Build ACL2
# =============================================================================
FROM ubuntu:24.04 AS acl2-builder

# Copy SBCL from builder
COPY --from=sbcl-builder /usr/local /usr/local

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git \
    libssl-dev \
    make \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /root

# ACL2 version argument
# The GitHub Action workflow supplies a value like ACL2_COMMIT=abc1234... (full commit hash)
# The default "master" is used when building locally without --build-arg.
ARG ACL2_COMMIT=master

# Clone ACL2 with shallow history (--depth 1 saves ~1.6 GB vs full clone)
# Git is included so users can run "git pull" to update ACL2 inside the container.
RUN git clone --depth 1 --branch ${ACL2_COMMIT} https://github.com/acl2/acl2.git acl2

# --------------------------------------------------------------------------
# ALTERNATIVE: Zipball download (smaller image, no git required)
#
# Pros: ~75-125 MB smaller image, faster download
# Cons: No "git pull" capability, requires ACL2_SNAPSHOT_INFO for version banner
#
# To use zipball instead:
#   1. Remove `git` from apt-get install above, add `unzip`
#   2. Replace the git clone above with:
#        ARG ACL2_SNAPSHOT_INFO="Local Docker build from ACL2 ${ACL2_COMMIT}"
#        RUN curl -fsSL "https://api.github.com/repos/acl2/acl2/zipball/${ACL2_COMMIT}" -o acl2.zip \
#            && unzip -q acl2.zip \
#            && mv acl2-acl2-* acl2 \
#            && rm acl2.zip
#        ENV ACL2_SNAPSHOT_INFO=${ACL2_SNAPSHOT_INFO}
#   3. Remove `git` from runtime stage apt-get install
# --------------------------------------------------------------------------

WORKDIR /root/acl2

# Create SBCL wrapper script with ACL2's recommended settings
# --dynamic-space-size 32000 is required for full regression (see acl2-init.lisp)
RUN echo '#!/bin/sh' > /usr/local/bin/sbcl-acl2 && \
    echo 'exec /usr/local/bin/sbcl --dynamic-space-size 32000 "$@"' >> /usr/local/bin/sbcl-acl2 && \
    chmod +x /usr/local/bin/sbcl-acl2

# Build ACL2
RUN make LISP=/usr/local/bin/sbcl-acl2

# Generate certdep files and detect ACL2 features.
# This is a lightweight alternative to "make basic" (which certifies books).
# Without this step, cert.pl fails with "Missing build/acl2-version.certdep".
# See books/build/features.sh for details on what this generates.
RUN cd books && make ACL2=/root/acl2/saved_acl2 build/Makefile-features

# Note: Books are NOT certified during build.
# Users certify the books they need when running the image.

# =============================================================================
# Stage 3: Runtime image
# =============================================================================
FROM ubuntu:24.04

# OCI labels (additional labels added by workflow)
LABEL org.opencontainers.image.title="ACL2"
LABEL org.opencontainers.image.description="ACL2 theorem prover built on SBCL"
LABEL org.opencontainers.image.licenses="BSD-3-Clause"
LABEL org.opencontainers.image.url="https://www.cs.utexas.edu/~moore/acl2/"

# Copy SBCL runtime
COPY --from=sbcl-builder /usr/local /usr/local

# Copy ACL2
COPY --from=acl2-builder /root/acl2 /root/acl2

# Runtime dependencies
# - build-essential: some books (e.g., quicklisp) compile C code during certification
# - git: allows "git pull" to update ACL2 inside the container
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    git \
    libssl3 \
    make \
    perl \
    && rm -rf /var/lib/apt/lists/*

# Create read-only test file required by books/oslib/tests/copy certification
RUN touch /root/foo && chmod a-w /root/foo

# ACL2 environment setup
# - bin/ contains the 'acl2' launcher script
# - books/build/ contains cert.pl and other build tools
ENV ACL2_ROOT="/root/acl2"
ENV ACL2="${ACL2_ROOT}/saved_acl2"
ENV PATH="${ACL2_ROOT}/bin:${ACL2_ROOT}/books/build:${PATH}"

# USER is required by oslib::default-tempfile-aux
ENV USER="root"

# Optional: Remove .out files after book certification to save space.
# Uncomment if disk space becomes an issue during large regressions.
# ENV CERT_PL_RM_OUTFILES="1"

WORKDIR /root/acl2

CMD ["acl2"]
