#!/bin/bash
# =============================================================================
# Build arm64 ACL2 Docker image locally and merge with amd64 from GitHub
# =============================================================================
#
# This script builds the arm64 image on an Apple Silicon Mac (where SBCL's
# floating-point trap support works) and creates a multi-platform manifest
# combining it with the amd64 image built on GitHub.
#
# Prerequisites:
#   - Apple Silicon Mac with Docker Desktop
#   - Logged in to GHCR: docker login ghcr.io -u USERNAME
#   - amd64 image already pushed by GitHub workflow
#
# Usage:
#   ./scripts/build-arm64-and-merge.sh \
#     --acl2-commit <full-commit-hash> \
#     --amd64-digest <sha256:...> \
#     --tag <short-tag> \
#     [--additional-tag <tag>]
#
# =============================================================================

set -euo pipefail

# Default values
REGISTRY="ghcr.io"
IMAGE_NAME="bendyarm/acl2"  # Change to kestrelinstitute/acl2 for production
ACL2_COMMIT=""
AMD64_DIGEST=""
TAG=""
ADDITIONAL_TAG=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --acl2-commit)
      ACL2_COMMIT="$2"
      shift 2
      ;;
    --amd64-digest)
      AMD64_DIGEST="$2"
      shift 2
      ;;
    --tag)
      TAG="$2"
      shift 2
      ;;
    --additional-tag)
      ADDITIONAL_TAG="$2"
      shift 2
      ;;
    --registry)
      REGISTRY="$2"
      shift 2
      ;;
    --image-name)
      IMAGE_NAME="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 --acl2-commit COMMIT --amd64-digest DIGEST --tag TAG [--additional-tag TAG]"
      echo ""
      echo "Options:"
      echo "  --acl2-commit     Full ACL2 commit hash (required)"
      echo "  --amd64-digest    Digest of amd64 image from GitHub (required)"
      echo "  --tag             Tag for the multi-platform manifest (required)"
      echo "  --additional-tag  Additional tag (optional, e.g., 'latest')"
      echo "  --registry        Container registry (default: ghcr.io)"
      echo "  --image-name      Image name (default: bendyarm/acl2)"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

# Validate required arguments
if [[ -z "$ACL2_COMMIT" ]]; then
  echo "Error: --acl2-commit is required"
  exit 1
fi
if [[ -z "$AMD64_DIGEST" ]]; then
  echo "Error: --amd64-digest is required"
  exit 1
fi
if [[ -z "$TAG" ]]; then
  echo "Error: --tag is required"
  exit 1
fi

IMAGE="${REGISTRY}/${IMAGE_NAME}"

echo "=============================================="
echo "ACL2 Docker arm64 Build and Merge"
echo "=============================================="
echo "Registry:     ${REGISTRY}"
echo "Image:        ${IMAGE_NAME}"
echo "ACL2 Commit:  ${ACL2_COMMIT}"
echo "amd64 Digest: ${AMD64_DIGEST}"
echo "Tag:          ${TAG}"
if [[ -n "$ADDITIONAL_TAG" ]]; then
  echo "Additional:   ${ADDITIONAL_TAG}"
fi
echo "=============================================="
echo ""

# Check we're on arm64
ARCH=$(uname -m)
if [[ "$ARCH" != "arm64" ]]; then
  echo "Warning: This script is intended for Apple Silicon Macs (arm64)"
  echo "Current architecture: $ARCH"
  read -p "Continue anyway? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
  fi
fi

# Check Docker is running
if ! docker info > /dev/null 2>&1; then
  echo "Error: Docker is not running"
  exit 1
fi

# Find the Dockerfile (script might be run from different directories)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
DOCKERFILE="${REPO_DIR}/Dockerfile"

if [[ ! -f "$DOCKERFILE" ]]; then
  echo "Error: Dockerfile not found at $DOCKERFILE"
  exit 1
fi

echo "=== Step 1: Building arm64 image ==="
echo "This may take 30-60 minutes..."
echo ""

docker build \
  --platform linux/arm64 \
  --build-arg ACL2_COMMIT="${ACL2_COMMIT}" \
  --label "org.opencontainers.image.revision=${ACL2_COMMIT}" \
  --label "org.opencontainers.image.source=https://github.com/acl2/acl2" \
  --label "org.opencontainers.image.description=ACL2 ${TAG} on SBCL (arm64)" \
  -t "${IMAGE}:arm64-temp" \
  -f "$DOCKERFILE" \
  "$REPO_DIR"

echo ""
echo "=== Step 2: Pushing arm64 image by digest ==="

docker push "${IMAGE}:arm64-temp"

# Get the digest of the pushed image
ARM64_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "${IMAGE}:arm64-temp" | cut -d@ -f2)

if [[ -z "$ARM64_DIGEST" ]]; then
  echo "Error: Failed to get arm64 digest"
  exit 1
fi

echo "arm64 digest: ${ARM64_DIGEST}"
echo ""

echo "=== Step 3: Creating multi-platform manifest ==="

# Create manifest with primary tag
docker buildx imagetools create \
  -t "${IMAGE}:${TAG}" \
  "${IMAGE}@${AMD64_DIGEST}" \
  "${IMAGE}@${ARM64_DIGEST}"

echo "Created: ${IMAGE}:${TAG}"

# Create manifest with additional tag if specified
if [[ -n "$ADDITIONAL_TAG" ]]; then
  docker buildx imagetools create \
    -t "${IMAGE}:${ADDITIONAL_TAG}" \
    "${IMAGE}@${AMD64_DIGEST}" \
    "${IMAGE}@${ARM64_DIGEST}"
  echo "Created: ${IMAGE}:${ADDITIONAL_TAG}"
fi

echo ""
echo "=== Step 4: Cleanup ==="

# Remove the temporary tag
docker rmi "${IMAGE}:arm64-temp" 2>/dev/null || true

echo ""
echo "=============================================="
echo "SUCCESS!"
echo "=============================================="
echo ""
echo "Multi-platform image: ${IMAGE}:${TAG}"
echo "  - amd64: ${AMD64_DIGEST} (built on GitHub, has attestation)"
echo "  - arm64: ${ARM64_DIGEST} (built locally, no attestation)"
echo ""
echo "To verify amd64 attestation:"
echo "  gh attestation verify oci://${IMAGE}@${AMD64_DIGEST} --owner $(echo $IMAGE_NAME | cut -d/ -f1)"
echo ""
echo "To test the image:"
echo "  docker run --rm ${IMAGE}:${TAG} acl2 -e ':q'"
echo ""
echo "To inspect the manifest:"
echo "  docker buildx imagetools inspect ${IMAGE}:${TAG}"
echo ""
