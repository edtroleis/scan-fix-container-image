#!/usr/bin/env bash
# write_lang_update_script <build_dir>
#
# Appends language-runtime upgrade blocks to <build_dir>/run-update.sh.
# Every block is a no-op when the toolchain is absent from the image —
# nothing is installed from scratch.

write_lang_update_script() {
    local build_dir="$1"

    cat >> "$build_dir/run-update.sh" <<'COMMON'

# ── Python ────────────────────────────────────────────────────────────────────
if command -v pip3 >/dev/null 2>&1; then
  pip3 install --upgrade pip --quiet 2>/dev/null || true
  pip3 list --outdated --format=freeze 2>/dev/null \
    | grep -v '^\-e' | cut -d= -f1 \
    | xargs -r pip3 install -U --quiet 2>/dev/null || true
  pip3 cache purge 2>/dev/null || true
fi

# ── Node.js ───────────────────────────────────────────────────────────────────
if command -v npm >/dev/null 2>&1; then
  npm update -g --silent 2>/dev/null || true
  npm cache clean --force 2>/dev/null || true
fi
if command -v yarn >/dev/null 2>&1; then
  yarn global upgrade 2>/dev/null || true
  yarn cache clean 2>/dev/null || true
fi

# ── Java (Maven) ──────────────────────────────────────────────────────────────
if command -v mvn >/dev/null 2>&1; then
  find / -name pom.xml -not -path "*/.m2/*" 2>/dev/null | head -5 \
    | while read -r pom; do
        mvn -f "$pom" versions:use-latest-releases -DgenerateBackupPoms=false -q 2>/dev/null || true
      done
fi

# ── Go binaries ───────────────────────────────────────────────────────────────
# Reads the module path embedded in each Go binary and rebuilds via go install.
# No-op when the Go toolchain is absent from the image.
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
}
