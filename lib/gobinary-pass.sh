#!/usr/bin/env bash
# run_gobinary_pass <pass2_image> <output_image> <restore_user> <build_dir>
#
# Scans <pass2_image> with Trivy (gobinary, ignore-unfixed) to find pre-compiled
# Go binaries that still carry fixable CVEs after the OS patching passes.
# For each such binary: extracts the main module path via `go version -m`,
# then runs `go install <module>@latest` and replaces the binary in-place.
#
# Go is injected via a multi-stage build (golang:latest) — no curl/wget/network
# access is required inside the target container.
#
# Falls back to tagging pass2 as output when no fixable gobinary CVEs remain
# or when `go install` fails (no upstream fix yet or build error).

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

    # Go is copied from golang:latest via multi-stage build and removed at the
    # end of the RUN command. --squash-all ensures it does not appear in the
    # final image regardless of intermediate layers.
    cat > "$build_dir/run-gobinary.sh" <<'SCRIPT'
#!/bin/sh
set -e

export PATH="/usr/local/go/bin:${PATH}"
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

rm -rf "${GOPATH}" /usr/local/go
SCRIPT

    chmod +x "$build_dir/run-gobinary.sh"

    cat > "$build_dir/Dockerfile.gobinary" <<EOF
FROM golang:latest AS _gobuilder

FROM ${pass2_image}
USER root
COPY --from=_gobuilder /usr/local/go /usr/local/go
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
