#!/usr/bin/env bash
# run_second_pass <pass1_image> <output_image> <os_id> <restore_user> <build_dir>
#
# Scans <pass1_image> with Trivy (JSON, vuln-only, ignore-unfixed), extracts
# OS packages that still have a fix available, and builds a second Dockerfile
# that upgrades only those packages without --skip-broken / --nobest.
#
# Falls back to tagging pass1 as output when:
#   - trivy or jq are absent
#   - the Trivy scan finds no remaining fixable OS packages
#
# Requires: write_targeted_upgrade_script and get_trivy_os_type from os-packages.sh

run_second_pass() {
    local pass1_image="$1"
    local output_image="$2"
    local os_id="$3"
    local restore_user="$4"
    local build_dir="$5"

    if ! command -v trivy &>/dev/null; then
        echo "==> trivy not found — installing ..."
        mkdir -p "$HOME/.local/bin"
        curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
            | sh -s -- -b "$HOME/.local/bin"
        export PATH="$HOME/.local/bin:$PATH"
    fi

    if ! command -v jq &>/dev/null; then
        echo "==> jq not found — using first-pass result."
        podman tag "$pass1_image" "$output_image"
        return 0
    fi

    echo "==> Scanning first-pass image for remaining fixable OS packages ..."

    local trivy_json="$build_dir/trivy-pass1.json"
    local pass1_tar="$build_dir/pass1.tar"

    podman save "$pass1_image" -o "$pass1_tar"

    # --scanners vuln: skip secret scanning (faster; we only need package CVEs)
    # --exit-code 0:  don't fail — we parse the JSON regardless
    trivy image \
        --exit-code 0 \
        --scanners vuln \
        --ignore-unfixed \
        --format json \
        --output "$trivy_json" \
        --input "$pass1_tar" 2>/dev/null || true

    local trivy_os_type
    trivy_os_type=$(get_trivy_os_type "$os_id")

    local fixable_packages
    fixable_packages=$(
        jq -r --arg t "$trivy_os_type" '
            .Results[]? |
            select(.Type == $t) |
            .Vulnerabilities[]? |
            select(.FixedVersion != null and .FixedVersion != "") |
            .PkgName
        ' "$trivy_json" 2>/dev/null \
        | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//'
    )

    if [[ -z "$fixable_packages" ]]; then
        echo "==> No remaining fixable OS packages — first-pass result is final."
        podman tag "$pass1_image" "$output_image"
        return 0
    fi

    echo "==> Packages with remaining fixes: ${fixable_packages}"
    echo "==> Running targeted second-pass upgrade (no --skip-broken) ..."

    write_targeted_upgrade_script "$os_id" "$fixable_packages" "$build_dir"

    # FROM uses the local pass1 image by name
    cat > "$build_dir/Dockerfile.pass2" <<EOF
FROM ${pass1_image}
USER 0
COPY run-targeted.sh /tmp/run-targeted.sh
RUN sh /tmp/run-targeted.sh && rm -f /tmp/run-targeted.sh
${restore_user}
EOF

    podman build \
        --squash-all \
        -t "$output_image" \
        -f "$build_dir/Dockerfile.pass2" \
        "$build_dir"

    echo "==> Second-pass complete: ${output_image}"
}
