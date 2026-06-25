#!/usr/bin/env bash
# write_os_update_script <os_id> <build_dir>
#   Writes <build_dir>/run-update.sh with the OS-appropriate full upgrade.
#
# write_targeted_upgrade_script <os_id> <packages> <build_dir>
#   Writes <build_dir>/run-targeted.sh to upgrade specific packages only,
#   without safety flags like --skip-broken. Used by the second pass.
#
# get_trivy_os_type <os_id>
#   Prints the Trivy Results[].Type value for the given OS ID.

write_os_update_script() {
    local os_id="$1"
    local build_dir="$2"

    case "$os_id" in

        ubuntu|debian)
            cat > "$build_dir/run-update.sh" <<'SCRIPT'
#!/bin/sh
set -e
apt-get update
apt-get upgrade -y --no-install-recommends
apt-get autoremove -y --purge
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
SCRIPT
            ;;

        rhel|centos|rocky|almalinux|fedora|amzn|ol)
            # --nobest --skip-broken: avoids breaking version-pinned deps common
            # in AI/GPU images where strict pins cannot be satisfied by latest.
            # Slim images (e.g. mysql:8.0 on Oracle Linux 9) ship microdnf only.
            cat > "$build_dir/run-update.sh" <<'SCRIPT'
#!/bin/sh
set -e
if command -v dnf >/dev/null 2>&1; then
    dnf upgrade -y --nodocs --setopt=install_weak_deps=False --nobest --skip-broken
    dnf clean all && rm -rf /var/cache/dnf
elif command -v microdnf >/dev/null 2>&1; then
    microdnf upgrade -y --nodocs
    microdnf clean all && rm -rf /var/cache/dnf
fi
SCRIPT
            ;;

        alpine)
            cat > "$build_dir/run-update.sh" <<'SCRIPT'
#!/bin/sh
set -e
apk upgrade --no-cache
SCRIPT
            ;;

        opensuse*|sles)
            cat > "$build_dir/run-update.sh" <<'SCRIPT'
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

    chmod +x "$build_dir/run-update.sh"
}

# Maps OS_ID to the value Trivy uses in Results[].Type (from JSON output).
get_trivy_os_type() {
    local os_id="$1"
    case "$os_id" in
        rhel|centos|rocky|almalinux|fedora) echo "redhat" ;;
        amzn)                               echo "amazon" ;;
        ol)                                 echo "oracle" ;;
        ubuntu)                             echo "ubuntu" ;;
        debian)                             echo "debian" ;;
        alpine)                             echo "alpine" ;;
        opensuse*|sles)                     echo "suse"   ;;
        *)                                  echo "unknown" ;;
    esac
}

# Generates <build_dir>/run-targeted.sh to upgrade a specific set of packages.
# Unlike write_os_update_script, this does NOT use --skip-broken / --nobest,
# so DNF will fail loudly if a package truly cannot be upgraded.
write_targeted_upgrade_script() {
    local os_id="$1"
    local packages="$2"   # space-separated package names from Trivy output
    local build_dir="$3"

    case "$os_id" in

        rhel|centos|rocky|almalinux|fedora|amzn|ol)
            cat > "$build_dir/run-targeted.sh" <<SCRIPT
#!/bin/sh
set -e
if command -v dnf >/dev/null 2>&1; then
    dnf upgrade -y --nodocs --setopt=install_weak_deps=False ${packages}
    dnf clean all && rm -rf /var/cache/dnf
elif command -v microdnf >/dev/null 2>&1; then
    microdnf upgrade -y --nodocs ${packages}
    microdnf clean all && rm -rf /var/cache/dnf
fi
SCRIPT
            ;;

        ubuntu|debian)
            cat > "$build_dir/run-targeted.sh" <<SCRIPT
#!/bin/sh
set -e
apt-get update
apt-get install -y --only-upgrade --no-install-recommends ${packages}
rm -rf /var/lib/apt/lists/*
SCRIPT
            ;;

        alpine)
            cat > "$build_dir/run-targeted.sh" <<SCRIPT
#!/bin/sh
set -e
apk add --no-cache --upgrade ${packages}
SCRIPT
            ;;

        opensuse*|sles)
            cat > "$build_dir/run-targeted.sh" <<SCRIPT
#!/bin/sh
set -e
zypper install --no-confirm ${packages}
zypper clean --all
SCRIPT
            ;;

    esac

    chmod +x "$build_dir/run-targeted.sh"
}
