#!/usr/bin/env bash
# patch-image.sh <source_image> <output_image>
#
# Detects the OS inside <source_image>, generates a Dockerfile that updates
# OS packages and language runtimes from public repositories, and builds
# <output_image>.
set -euo pipefail

SOURCE_IMAGE="$1"
OUTPUT_IMAGE="$2"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/detect-os.sh
source "$SCRIPT_DIR/lib/detect-os.sh"
# shellcheck source=lib/os-packages.sh
source "$SCRIPT_DIR/lib/os-packages.sh"
# shellcheck source=lib/lang-packages.sh
source "$SCRIPT_DIR/lib/lang-packages.sh"
# shellcheck source=lib/second-pass.sh
source "$SCRIPT_DIR/lib/second-pass.sh"
# shellcheck source=lib/gobinary-pass.sh
source "$SCRIPT_DIR/lib/gobinary-pass.sh"

# ── Setup ─────────────────────────────────────────────────────────────────────
BUILD_DIR=$(mktemp -d)
PASS1_IMAGE="patch-pass1-$$"   # temporary; removed after second pass
PASS2_IMAGE="patch-pass2-$$"   # temporary; removed after gobinary pass

cleanup() {
    [[ -n "${CONTAINER_ID:-}" ]] && podman rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true
    podman rmi "$PASS1_IMAGE" >/dev/null 2>&1 || true
    podman rmi "$PASS2_IMAGE" >/dev/null 2>&1 || true
    rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

# ── Detect OS ─────────────────────────────────────────────────────────────────
echo "==> Detecting OS in ${SOURCE_IMAGE} ..."
if ! detect_os "$SOURCE_IMAGE" "$BUILD_DIR"; then
    echo "==> Skipping patch — image has no standard OS or is scratch/distroless."
    podman tag "$SOURCE_IMAGE" "$OUTPUT_IMAGE"
    exit 0
fi
echo "==> Detected OS: ${OS_ID} ${OS_VERSION}"

# ── Generate update script ────────────────────────────────────────────────────
write_os_update_script "$OS_ID" "$BUILD_DIR"
write_lang_update_script "$BUILD_DIR"

# ── Build patched image ───────────────────────────────────────────────────────
RESTORE_USER=""
if [[ -n "${ORIGINAL_USER:-}" && "$ORIGINAL_USER" != "root" && "$ORIGINAL_USER" != "0" ]]; then
    RESTORE_USER="USER ${ORIGINAL_USER}"
fi

cat > "$BUILD_DIR/Dockerfile" <<EOF
FROM ${SOURCE_IMAGE}
USER root
COPY run-update.sh /tmp/run-update.sh
RUN sh /tmp/run-update.sh && rm -f /tmp/run-update.sh
${RESTORE_USER}
EOF

echo ""
echo "==> Dockerfile:"
cat "$BUILD_DIR/Dockerfile"
echo ""

echo "==> Building pass-1 image ..."
podman build \
    --squash-all \
    -t "$PASS1_IMAGE" \
    -f "$BUILD_DIR/Dockerfile" \
    "$BUILD_DIR"

# ── Second-pass: upgrade OS packages that still have a fix after pass 1 ───────
run_second_pass "$PASS1_IMAGE" "$PASS2_IMAGE" "$OS_ID" "$RESTORE_USER" "$BUILD_DIR"

# ── Gobinary-pass: rebuild Go binaries that still carry fixable CVEs ──────────
run_gobinary_pass "$PASS2_IMAGE" "$OUTPUT_IMAGE" "$RESTORE_USER" "$BUILD_DIR"

echo "==> Done: ${OUTPUT_IMAGE}"
