#!/usr/bin/env bash
# run_gobinary_pass <pass2_image> <output_image> <restore_user> <build_dir>
#
# Scans <pass2_image> with Trivy (gobinary, ignore-unfixed) to find pre-compiled
# Go binaries that still carry fixable CVEs after the OS patching passes.
# For each such binary: extracts the main module path via `go version -m`,
# installs the Go toolchain if absent from the image, then runs
# `go install <module>@latest` and replaces the binary in-place.
#
# Falls back to tagging pass2 as output when:
#   - no fixable gobinary CVEs remain
#   - the host architecture is unsupported for Go installation
#   - `go install` fails (no upstream fix yet or build error)

run_gobinary_pass() {
    local pass2_image="$1"
    local output_image="$2"
    local restore_user="$3"
    local build_dir="$4"

    local pass2_tar="$build_dir/pass2.tar"
    local trivy_json="$build_dir/trivy-pass2.json"

    echo "==> Scanning for remaining gobinary CVEs ..."
    podman save "$pass2_image" -o "$pass2_tar"

    trivy image \
        --exit-code 0 \
        --scanners vuln \
        --ignore-unfixed \
        --format json \
        --output "$trivy_json" \
        --input "$pass2_tar" 2>/dev/null || true

    # Extract paths of gobinary targets that have at least one fixable CVE.
    # Trivy reports .Target relative to the container root (no leading /).
    jq -r '
        .Results[]? |
        select(.Type == "gobinary") |
        select(
            (.Vulnerabilities // []) |
            any(.FixedVersion != null and .FixedVersion != "")
        ) |
        .Target
    ' "$trivy_json" 2>/dev/null | sort -u > "$build_dir/vuln-bins.txt"

    if [[ ! -s "$build_dir/vuln-bins.txt" ]]; then
        echo "==> No fixable gobinary CVEs — skipping gobinary pass."
        podman tag "$pass2_image" "$output_image"
        return 0
    fi

    echo "==> Fixable gobinary CVEs found in:"
    sed 's/^/    /' "$build_dir/vuln-bins.txt"
    echo "==> Running gobinary upgrade pass ..."

    # ── Script that runs inside the container during podman build ────────────
    cat > "$build_dir/run-gobinary.sh" <<'SCRIPT'
#!/bin/sh
set -e

_fetch() {
    if command -v curl >/dev/null 2>&1; then
        curl -sfL "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- "$1"
    else
        echo "==> No curl or wget available — cannot install Go." && exit 0
    fi
}

GO_INSTALLED_HERE=0

if ! command -v go >/dev/null 2>&1; then
    GO_INSTALLED_HERE=1
    case "$(uname -m)" in
        x86_64)  GOARCH=amd64  ;;
        aarch64) GOARCH=arm64  ;;
        armv7l)  GOARCH=armv6l ;;
        *)
            echo "==> Unsupported arch for Go install: $(uname -m) — skipping gobinary pass."
            exit 0
            ;;
    esac
    GOVER=$(_fetch "https://go.dev/VERSION?m=text" | head -1)
    echo "==> Installing ${GOVER} (${GOARCH}) ..."
    _fetch "https://dl.google.com/go/${GOVER}.linux-${GOARCH}.tar.gz" \
        | tar -C /usr/local -xz
    export PATH="/usr/local/go/bin:${PATH}"
fi

export GOPATH=/tmp/_gopath
export GOBIN=/tmp/_gopath/bin
mkdir -p "${GOBIN}"

while IFS= read -r rel_path; do
    [ -z "$rel_path" ] && continue
    abs="/${rel_path}"
    [ -f "$abs" ] || { echo "    skip (not found): ${abs}"; continue; }

    module=$(go version -m "$abs" 2>/dev/null \
             | awk '/^[[:space:]]*path[[:space:]]/ { print $2; exit }')
    if [ -z "$module" ]; then
        echo "    skip (no module path): ${abs}"
        continue
    fi

    echo "==> ${abs}: go install ${module}@latest"
    if GO111MODULE=on go install "${module}@latest" 2>/dev/null; then
        bin_name=$(basename "$abs")
        if [ -f "${GOBIN}/${bin_name}" ]; then
            mv "${GOBIN}/${bin_name}" "$abs"
            chmod 755 "$abs"
            echo "    replaced: ${abs}"
        else
            echo "    installed but binary not found at ${GOBIN}/${bin_name}"
        fi
    else
        echo "    go install failed (no upstream fix yet): ${module}"
    fi
done < /tmp/vuln-bins.txt

rm -rf "${GOPATH}"
if [ "${GO_INSTALLED_HERE}" -eq 1 ]; then
    rm -rf /usr/local/go
fi
SCRIPT

    chmod +x "$build_dir/run-gobinary.sh"

    cat > "$build_dir/Dockerfile.gobinary" <<EOF
FROM ${pass2_image}
USER root
COPY run-gobinary.sh /tmp/run-gobinary.sh
COPY vuln-bins.txt   /tmp/vuln-bins.txt
RUN sh /tmp/run-gobinary.sh && rm -f /tmp/run-gobinary.sh /tmp/vuln-bins.txt
${restore_user}
EOF

    podman build \
        --squash-all \
        -t "$output_image" \
        -f "$build_dir/Dockerfile.gobinary" \
        "$build_dir"

    echo "==> Gobinary pass complete: ${output_image}"
}
