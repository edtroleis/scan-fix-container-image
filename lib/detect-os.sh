#!/usr/bin/env bash
# detect_os <image> <build_dir>
#
# Creates a stopped container from <image>, copies /etc/os-release without
# starting the container (safe for AI models, GPU-only, distroless images),
# and exports OS metadata as globals:
#   CONTAINER_ID    — caller is responsible for cleanup via podman rm
#   OS_ID           — value of ID= field (e.g. ubuntu, rhel, alpine)
#   OS_VERSION      — value of VERSION_ID= field (e.g. 24.04, 9, 3.20)
#   ORIGINAL_USER   — USER configured in the image (may be empty)

detect_os() {
    local image="$1"
    local build_dir="$2"

    CONTAINER_ID=$(podman create "$image" 2>/dev/null || true)
    if [[ -z "$CONTAINER_ID" ]]; then
        echo "[WARN] Could not create container from ${image}" >&2
        return 1
    fi

    podman cp "${CONTAINER_ID}:/etc/os-release" "$build_dir/" 2>/dev/null || true

    local os_release
    os_release=$(cat "$build_dir/os-release" 2>/dev/null || true)

    ORIGINAL_USER=$(podman inspect "$CONTAINER_ID" --format '{{.Config.User}}' 2>/dev/null || true)

    if [[ -z "$os_release" ]]; then
        echo "[WARN] /etc/os-release not found in ${image} — scratch/distroless image, no OS packages to patch" >&2
        return 1
    fi

    OS_ID=$(echo "$os_release"      | grep "^ID="         | cut -d= -f2 | tr -d '"' || true)
    OS_VERSION=$(echo "$os_release" | grep "^VERSION_ID=" | cut -d= -f2 | tr -d '"' || true)
}
