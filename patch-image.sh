#!/usr/bin/env bash
# patch-image.sh <source_image> <output_image>
#
# Detects the OS inside <source_image>, generates a Dockerfile that updates
# OS packages via the local Nexus proxy, and builds <output_image>.
#
# Nexus credentials are passed via podman build --secret so they are mounted
# as tmpfs during the RUN step only — never stored in any image layer.
#
# Environment variables (set by GitHub Actions secrets / variables):
#   NEXUS_HOST      - Nexus host:port              (default: localhost:8081)
#   NEXUS_USER      - Nexus username               (from secret NEXUS_USER)
#   NEXUS_PASSWORD  - Nexus password               (from secret NEXUS_PASSWORD)
set -euo pipefail

SOURCE_IMAGE="$1"
OUTPUT_IMAGE="$2"

NEXUS_HOST="${NEXUS_HOST:-localhost:8081}"
NEXUS_USER="${NEXUS_USER:-}"
NEXUS_PASSWORD="${NEXUS_PASSWORD:-}"

echo "==> Detecting OS in ${SOURCE_IMAGE} ..."

# podman create + podman cp: reads /etc/os-release without starting the container,
# avoiding entrypoint issues (AI models, GPU-only images, distroless, etc.)
CONTAINER_ID=$(podman create "$SOURCE_IMAGE" 2>/dev/null || true)
if [[ -z "$CONTAINER_ID" ]]; then
    echo "[ERROR] Could not create container from ${SOURCE_IMAGE}" >&2
    exit 1
fi

TMPDIR=$(mktemp -d)
# Redirect stdout so podman rm does not print the container ID to the build log
trap 'podman rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true; rm -rf "$TMPDIR"' EXIT

podman cp "${CONTAINER_ID}:/etc/os-release" "$TMPDIR/" 2>/dev/null || true
os_release=$(cat "$TMPDIR/os-release" 2>/dev/null || true)
ORIGINAL_USER=$(podman inspect "$CONTAINER_ID" --format '{{.Config.User}}' 2>/dev/null || true)

if [[ -z "$os_release" ]]; then
    echo "[ERROR] /etc/os-release not found in ${SOURCE_IMAGE}" >&2
    exit 1
fi

# grep returns exit 1 when no match is found; || true prevents set -o pipefail
# from exiting the script for fields absent in some OS families
# (e.g. VERSION_CODENAME is not present in RHEL/Fedora/Alpine os-release)
os_id=$(echo "$os_release"             | grep "^ID="               | cut -d= -f2 | tr -d '"' || true)
version_codename=$(echo "$os_release"  | grep "^VERSION_CODENAME=" | cut -d= -f2 | tr -d '"' || true)
os_version=$(echo "$os_release"        | grep "^VERSION_ID="       | cut -d= -f2 | tr -d '"' || true)
alpine_minor=$(echo "$os_version"      | cut -d. -f1-2 || true)

echo "==> Detected OS: ${os_id} ${os_version} ${version_codename}"

# Generate an OS-specific update script.
# The script reads Nexus credentials from /run/secrets/nexus_creds at build
# time (mounted by podman build --secret). Credentials never appear in the
# Dockerfile or in any image layer.
# Variables expanded by bash NOW: ${NEXUS_HOST}, ${version_codename}, ${alpine_minor}
# Variables kept for the generated script (escaped): \${CREDS}, \${NUSER}, \${AUTH}
case "$os_id" in
    ubuntu)
        cat > "$TMPDIR/run-update.sh" <<SCRIPT
#!/bin/sh
set -e
CREDS=\$(cat /run/secrets/nexus_creds 2>/dev/null || true)
NUSER=\${CREDS%%:*}; NPASS=\${CREDS#*:}
AUTH=""; [ -n "\$NUSER" ] && [ -n "\$NPASS" ] && AUTH="\${NUSER}:\${NPASS}@"
echo "deb [trusted=yes] http://\${AUTH}${NEXUS_HOST}/repository/repo-apt-ubuntu-proxy/ ${version_codename} main restricted universe multiverse" > /etc/apt/sources.list.d/nexus.list
apt-get -o Acquire::AllowInsecureRepositories=true update
apt-get upgrade -y --no-install-recommends
apt-get autoremove -y --purge
rm -f /etc/apt/sources.list.d/nexus.list
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
SCRIPT
        ;;
    debian)
        cat > "$TMPDIR/run-update.sh" <<SCRIPT
#!/bin/sh
set -e
CREDS=\$(cat /run/secrets/nexus_creds 2>/dev/null || true)
NUSER=\${CREDS%%:*}; NPASS=\${CREDS#*:}
AUTH=""; [ -n "\$NUSER" ] && [ -n "\$NPASS" ] && AUTH="\${NUSER}:\${NPASS}@"
echo "deb [trusted=yes] http://\${AUTH}${NEXUS_HOST}/repository/repo-apt-debian-proxy/ ${version_codename} main contrib non-free" > /etc/apt/sources.list.d/nexus.list
apt-get -o Acquire::AllowInsecureRepositories=true update
apt-get upgrade -y --no-install-recommends
apt-get autoremove -y --purge
rm -f /etc/apt/sources.list.d/nexus.list
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
SCRIPT
        ;;
    rhel|centos|rocky|almalinux)
        # repo-rpm-rhel: RHEL UBI 9 BaseOS + AppStream only.
        # --disablerepo='*' silences EPEL, Copr, and any other repos baked into
        # the image to prevent el9/fc43 version conflicts.
        cat > "$TMPDIR/run-update.sh" <<SCRIPT
#!/bin/sh
set -e
CREDS=\$(cat /run/secrets/nexus_creds 2>/dev/null || true)
NUSER=\${CREDS%%:*}; NPASS=\${CREDS#*:}
AUTH=""; [ -n "\$NUSER" ] && [ -n "\$NPASS" ] && AUTH="\${NUSER}:\${NPASS}@"
printf '[nexus-rpm-rhel]\nname=Nexus RHEL\nbaseurl=http://%s${NEXUS_HOST}/repository/repo-rpm-rhel/\nenabled=1\ngpgcheck=0\n' "\$AUTH" > /etc/yum.repos.d/nexus-rhel.repo
dnf upgrade -y --nodocs --setopt=install_weak_deps=False --nobest --skip-broken \
    --disablerepo='*' --enablerepo='nexus-rpm-rhel'
dnf clean all && rm -rf /var/cache/dnf
rm -f /etc/yum.repos.d/nexus-rhel.repo
SCRIPT
        ;;
    fedora)
        # repo-rpm-fedora: Fedora 43 releases + updates only.
        # --disablerepo='*' prevents mixing with RHEL el9 packages.
        cat > "$TMPDIR/run-update.sh" <<SCRIPT
#!/bin/sh
set -e
CREDS=\$(cat /run/secrets/nexus_creds 2>/dev/null || true)
NUSER=\${CREDS%%:*}; NPASS=\${CREDS#*:}
AUTH=""; [ -n "\$NUSER" ] && [ -n "\$NPASS" ] && AUTH="\${NUSER}:\${NPASS}@"
printf '[nexus-rpm-fedora]\nname=Nexus Fedora\nbaseurl=http://%s${NEXUS_HOST}/repository/repo-rpm-fedora/\nenabled=1\ngpgcheck=0\n' "\$AUTH" > /etc/yum.repos.d/nexus-fedora.repo
dnf upgrade -y --nodocs --setopt=install_weak_deps=False --nobest --skip-broken \
    --disablerepo='*' --enablerepo='nexus-rpm-fedora'
dnf clean all && rm -rf /var/cache/dnf
rm -f /etc/yum.repos.d/nexus-fedora.repo
SCRIPT
        ;;
    amzn)
        # repo-rpm-amz: mixed group (local + fedora + rhel) for Amazon Linux.
        cat > "$TMPDIR/run-update.sh" <<SCRIPT
#!/bin/sh
set -e
CREDS=\$(cat /run/secrets/nexus_creds 2>/dev/null || true)
NUSER=\${CREDS%%:*}; NPASS=\${CREDS#*:}
AUTH=""; [ -n "\$NUSER" ] && [ -n "\$NPASS" ] && AUTH="\${NUSER}:\${NPASS}@"
printf '[nexus-rpm-amz]\nname=Nexus AMZ\nbaseurl=http://%s${NEXUS_HOST}/repository/repo-rpm-amz/\nenabled=1\ngpgcheck=0\n' "\$AUTH" > /etc/yum.repos.d/nexus-amz.repo
dnf upgrade -y --nodocs --setopt=install_weak_deps=False --nobest --skip-broken
dnf clean all && rm -rf /var/cache/dnf
rm -f /etc/yum.repos.d/nexus-amz.repo
SCRIPT
        ;;
    alpine)
        cat > "$TMPDIR/run-update.sh" <<SCRIPT
#!/bin/sh
set -e
cp /etc/apk/repositories /etc/apk/repositories.bak
CREDS=\$(cat /run/secrets/nexus_creds 2>/dev/null || true)
NUSER=\${CREDS%%:*}; NPASS=\${CREDS#*:}
AUTH=""; [ -n "\$NUSER" ] && [ -n "\$NPASS" ] && AUTH="\${NUSER}:\${NPASS}@"
printf 'http://%s${NEXUS_HOST}/repository/repo-apk/alpine/v${alpine_minor}/main\nhttp://%s${NEXUS_HOST}/repository/repo-apk/alpine/v${alpine_minor}/community\n' "\$AUTH" "\$AUTH" > /etc/apk/repositories
apk upgrade --no-cache --allow-untrusted
mv /etc/apk/repositories.bak /etc/apk/repositories
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

# Append language-level package upgrades after the OS-specific block.
# Each section is a no-op when the toolchain is absent from the image.
# Uses a quoted heredoc so $ signs are literal (evaluated inside the container,
# not by this script).
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

COMMON

# Go block is a separate heredoc (unquoted) so ${NEXUS_HOST} expands at
# script-generation time while container-time variables are escaped with \.
cat >> "$TMPDIR/run-update.sh" <<GOBLOCK

# ── Go binaries ───────────────────────────────────────────────────────────────
# Reads the module path embedded in each Go binary and rebuilds it via
# go install @latest routed through the Nexus Go proxy.
# No-op when the Go toolchain is absent from the image.
if command -v go >/dev/null 2>&1; then
  find / -xdev -maxdepth 6 -type f -executable 2>/dev/null \\
    | while read -r bin; do
        pkg=\$(go version -m "\$bin" 2>/dev/null \\
              | awk '/^[[:space:]]*path[[:space:]]/ { print \$2; exit }')
        [ -n "\$pkg" ] && GOPROXY="http://${NEXUS_HOST}/repository/repo-go,direct" \\
          GO111MODULE=on go install "\${pkg}@latest" 2>/dev/null || true
      done
  go clean -cache 2>/dev/null || true
fi
GOBLOCK

RESTORE_USER=""
if [[ -n "$ORIGINAL_USER" && "$ORIGINAL_USER" != "root" && "$ORIGINAL_USER" != "0" ]]; then
    RESTORE_USER="USER ${ORIGINAL_USER}"
fi

cat > "$TMPDIR/Dockerfile" <<EOF
FROM ${SOURCE_IMAGE}
USER root
COPY run-update.sh /tmp/run-update.sh
RUN --mount=type=secret,id=nexus_creds sh /tmp/run-update.sh && rm -f /tmp/run-update.sh
${RESTORE_USER}
EOF

echo ""
echo "==> Dockerfile:"
cat "$TMPDIR/Dockerfile"
echo ""

# Write credentials to a temp file for podman build --secret.
# The secret is mounted as tmpfs at /run/secrets/nexus_creds during RUN only.
# It is never written to any image layer or visible in build logs.
printf '%s:%s' "${NEXUS_USER}" "${NEXUS_PASSWORD}" > "$TMPDIR/nexus_creds"
chmod 600 "$TMPDIR/nexus_creds"

echo "==> Building ${OUTPUT_IMAGE} ..."
# --network=host : RUN commands reach localhost (Nexus on the host machine)
# --squash-all   : single layer — no intermediate state (repo configs) persists
# --secret       : credentials as tmpfs, visible only during RUN, not in image
# Build context = $TMPDIR (contains Dockerfile + run-update.sh)
podman build \
    --squash-all \
    --network=host \
    --secret "id=nexus_creds,src=${TMPDIR}/nexus_creds" \
    -t "$OUTPUT_IMAGE" \
    -f "$TMPDIR/Dockerfile" \
    "$TMPDIR"

echo "==> Done: ${OUTPUT_IMAGE}"
