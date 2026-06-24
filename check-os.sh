#!/bin/bash

UPDATED_DIR="$(dirname "$0")/updated"

images=(
  # Debian family (docker.io)
  "docker.io/library/debian:latest"
  "docker.io/library/ubuntu:latest"

  # Alpine (docker.io)
  "docker.io/library/alpine:latest"

  # Fedora (docker.io)
  "docker.io/library/fedora:latest"

  # Amazon Linux (docker.io)
  "docker.io/library/amazonlinux:latest"

  # Node.js (docker.io)
  "docker.io/library/node:22"

  # Java (docker.io)
  "docker.io/library/maven:3.9-eclipse-temurin-21"

  # MongoDB (docker.io)
  "docker.io/library/mongo:latest"

  # RHEL UBI (registry.access.redhat.com)
  "registry.access.redhat.com/ubi9/ubi:latest"
  "registry.access.redhat.com/ubi9/ubi-minimal:latest"
  "registry.access.redhat.com/ubi10/ubi:latest"
  "registry.access.redhat.com/ubi10/ubi-minimal:latest"
)

runtime_update_cmd() {
  local runtime="$1"
  case "$runtime" in
    python3|python) echo "pip install --upgrade pip && pip list --outdated --format=freeze | cut -d= -f1 | xargs pip install --upgrade" ;;
    node)           echo "npm update -g" ;;
    java)           echo "mvn versions:use-latest-releases  # or: gradle dependencyUpdates" ;;
    ruby)           echo "gem update" ;;
    go)             echo "go get -u all" ;;
    perl)           echo "cpan -u" ;;
    php)            echo "composer update" ;;
    rustc)          echo "cargo update" ;;
    *)              echo "[unknown]" ;;
  esac
}

image_dir_name() {
  local name="${1#docker.io/library/}"
  name="${name#registry.access.redhat.com/}"
  echo "$name" | tr '/:.@' '-'
}

new_image_tag() {
  local tag="${1##*:}"
  local base="${1%:*}"
  echo "${base}:${tag}-updated"
}

for image in "${images[@]}"; do
  if ! podman image exists "$image" 2>/dev/null; then
    echo "Pulling $image ..."
    podman pull "$image" > /dev/null 2>&1 || { echo "$image -> [pull failed]"; continue; }
  fi

  os_release=$(podman run --rm "$image" cat /etc/os-release 2>/dev/null)

  if [ -z "$os_release" ]; then
    echo "[$image]"
    echo "  [os]                -> [no /etc/os-release]"
    echo ""
    continue
  fi

  os_id=$(echo "$os_release"      | grep "^ID="         | cut -d= -f2 | tr -d '"')
  os_version=$(echo "$os_release" | grep "^VERSION_ID=" | cut -d= -f2 | tr -d '"')

  case "$os_id" in
    debian|ubuntu)
      os_update="apt-get update && apt-get upgrade -y --no-install-recommends && apt-get autoremove -y --purge"
      os_cleanup="rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*"
      ;;
    rhel|centos|rocky|almalinux|fedora|amzn)
      os_update="dnf update -y --nodocs --setopt=install_weak_deps=False"
      os_cleanup="dnf clean all && rm -rf /var/cache/dnf"
      ;;
    alpine)
      os_update="apk upgrade --no-cache"
      os_cleanup=""
      ;;
    opensuse*|sles)
      os_update="zypper update -y"
      os_cleanup="zypper clean --all"
      ;;
    *)
      os_update="[unknown package manager for: $os_id]"
      os_cleanup=""
      ;;
  esac

  runtimes=$(podman run --rm "$image" sh -c '
    for runtime in python3 python node java ruby go perl php rustc; do
      if command -v $runtime > /dev/null 2>&1; then
        version=$($runtime --version 2>&1 | head -1)
        printf "%s|%s\n" "$runtime" "$version"
      fi
    done
  ' 2>/dev/null)

  echo "[$image]"
  echo "  [os]                -> $os_id ${os_version:+$os_version}"
  echo "  [update os pkgs]    -> $os_update"

  if [ -n "$runtimes" ]; then
    while IFS="|" read -r runtime version; do
      update_cmd=$(runtime_update_cmd "$runtime")
      echo "  [runtime]           -> $runtime $version"
      echo "  [update libs]       -> $update_cmd"
    done <<< "$runtimes"
  else
    echo "  [runtime]           -> none detected"
    echo "  [update libs]       -> n/a"
  fi

  # Generate Dockerfile
  df_dir="$UPDATED_DIR/$(image_dir_name "$image")"
  mkdir -p "$df_dir"
  df_file="$df_dir/Dockerfile"
  new_image=$(new_image_tag "$image")

  if [ -n "$os_cleanup" ]; then
    df_content="FROM $image
RUN $os_update \\
    && $os_cleanup"
  else
    df_content="FROM $image
RUN $os_update"
  fi

  echo "$df_content" > "$df_file"

  echo "  [dockerfile]        -> $df_dir/Dockerfile"
  echo "  [build cmd]         -> podman build --squash-all -t $new_image -f $df_file ."
  echo ""
done
