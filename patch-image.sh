#!/usr/bin/env bash
# patch-image.sh <source_image> <output_image>
#
# Detects the OS inside <source_image>, generates a Dockerfile that updates
# OS packages and language runtimes from public repositories, and builds
# <output_image>.
set -euo pipefail

SOURCE_IMAGE="$1"
OUTPUT_IMAGE="$2"

echo "==> Detecting OS in ${SOURCE_IMAGE} ..."

# podman create + podman cp: reads /etc/os-release without starting the container,
# avoiding entrypoint issues (AI models, GPU-only images, distroless, etc.)
CONTAINER_ID=$(podman create "$SOURCE_IMAGE" 2>/dev/null || true)
if [[ -z "$CONTAINER_ID" ]]; then
    echo "[ERROR] Could not create container from ${SOURCE_IMAGE}" >&2
    exit 1
fi

TMPDIR=$(mktemp -d)
trap 'podman rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true; rm -rf "$TMPDIR"' EXIT

podman cp "${CONTAINER_ID}:/etc/os-release" "$TMPDIR/" 2>/dev/null || true
os_release=$(cat "$TMPDIR/os-release" 2>/dev/null || true)
ORIGINAL_USER=$(podman inspect "$CONTAINER_ID" --format '{{.Config.User}}' 2>/dev/null || true)

if [[ -z "$os_release" ]]; then
    echo "[ERROR] /etc/os-release not found in ${SOURCE_IMAGE}" >&2
    exit 1
fi

os_id=$(echo "$os_release"             | grep "^ID="               | cut -d= -f2 | tr -d '"' || true)
version_codename=$(echo "$os_release"  | grep "^VERSION_CODENAME=" | cut -d= -f2 | tr -d '"' || true)
os_version=$(echo "$os_release"        | grep "^VERSION_ID="       | cut -d= -f2 | tr -d '"' || true)
alpine_minor=$(echo "$os_version"      | cut -d. -f1-2 || true)

echo "==> Detected OS: ${os_id} ${os_version} ${version_codename}"

case "$os_id" in
    ubuntu|debian)
        cat > "$TMPDIR/run-update.sh" <<'SCRIPT'
#!/bin/sh
set -e
apt-get update
apt-get upgrade -y --no-install-recommends
apt-get autoremove -y --purge
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
SCRIPT
        ;;
    rhel|centos|rocky|almalinux)
        cat > "$TMPDIR/run-update.sh" <<'SCRIPT'
#!/bin/sh
set -e
dnf upgrade -y --nodocs --setopt=install_weak_deps=False --nobest --skip-broken
dnf clean all && rm -rf /var/cache/dnf
SCRIPT
        ;;
    fedora)
        cat > "$TMPDIR/run-update.sh" <<'SCRIPT'
#!/bin/sh
set -e
dnf upgrade -y --nodocs --setopt=install_weak_deps=False --nobest --skip-broken
dnf clean all && rm -rf /var/cache/dnf
SCRIPT
        ;;
    amzn)
        cat > "$TMPDIR/run-update.sh" <<'SCRIPT'
#!/bin/sh
set -e
dnf upgrade -y --nodocs --setopt=install_weak_deps=False --nobest --skip-broken
dnf clean all && rm -rf /var/cache/dnf
SCRIPT
        ;;
    alpine)
        cat > "$TMPDIR/run-update.sh" <<'SCRIPT'
#!/bin/sh
set -e
apk upgrade --no-cache
SCRIPT
        ;;
    opensuse*|sles)
        cat > "$TMPDIR/run-update.sh" <<'SCRIPT'
#!/bin/sh
set -e
zypper update -y
zypper clean --all
SCRIPT
        ;;
    *)
        echo "[ERROR] Unknown OS: ${os_id} — cannot determine package manager" >&2
        exit 1
        ;;
esac

chmod +x "$TMPDIR/run-update.sh"

# Append language-level package upgrades (best-effort; each section is a
# no-op when the toolchain is absent from the image).
cat >> "$TMPDIR/run-update.sh" <<'COMMON'

# ── Python packages ──────────────────────────────────────────────────────────
if command -v pip3 >/dev/null 2>&1; then
  pip3 install --upgrade pip --quiet 2>/dev/null || true
  pip3 list --outdated --format=freeze 2>/dev/null \
    | grep -v '^\-e' | cut -d= -f1 \
    | xargs -r pip3 install -U --quiet 2>/dev/null || true
  pip3 cache purge 2>/dev/null || true
fi

# ── Node.js packages ─────────────────────────────────────────────────────────
if command -v npm >/dev/null 2>&1; then
  npm update -g --silent 2>/dev/null || true
  npm cache clean --force 2>/dev/null || true
fi
if command -v yarn >/dev/null 2>&1; then
  yarn global upgrade 2>/dev/null || true
  yarn cache clean 2>/dev/null || true
fi

# ── Java (Maven) ─────────────────────────────────────────────────────────────
if command -v mvn >/dev/null 2>&1; then
  find / -name pom.xml -not -path "*/.m2/*" 2>/dev/null | head -5 \
    | while read -r pom; do
        mvn -f "$pom" versions:use-latest-releases -DgenerateBackupPoms=false -q 2>/dev/null || true
      done
fi

# ── Go binaries ───────────────────────────────────────────────────────────────
# Reads the module path embedded in each Go binary and rebuilds it via
# go install @latest. No-op when the Go toolchain is absent from the image.
if command -v go >/dev/null 2>&1; then
  find / -xdev -maxdepth 6 -type f -executable 2>/dev/null \
    | while read -r bin; do
        pkg=$(go version -m "$bin" 2>/dev/null \
              | awk '/^[[:space:]]*path[[:space:]]/ { print $2; exit }')
        [ -n "$pkg" ] && GO111MODULE=on go install "${pkg}@latest" 2>/dev/null || true
      done
  go clean -cache 2>/dev/null || true
fi
COMMON

RESTORE_USER=""
if [[ -n "$ORIGINAL_USER" && "$ORIGINAL_USER" != "root" && "$ORIGINAL_USER" != "0" ]]; then
    RESTORE_USER="USER ${ORIGINAL_USER}"
fi

cat > "$TMPDIR/Dockerfile" <<EOF
FROM ${SOURCE_IMAGE}
USER root
COPY run-update.sh /tmp/run-update.sh
RUN sh /tmp/run-update.sh && rm -f /tmp/run-update.sh
${RESTORE_USER}
EOF

echo ""
echo "==> Dockerfile:"
cat "$TMPDIR/Dockerfile"
echo ""

echo "==> Building ${OUTPUT_IMAGE} ..."
podman build \
    --squash-all \
    -t "$OUTPUT_IMAGE" \
    -f "$TMPDIR/Dockerfile" \
    "$TMPDIR"

echo "==> Done: ${OUTPUT_IMAGE}"
