# Scan, patch, and publish container images

Scan public container images for CVEs using Trivy and automatically patch them by upgrading OS and language-runtime packages from public repositories. Rescans the patched image and only publishes if it passes.

> **Simulated registry:** `podman login` and `podman push` are commented out in the publish job. The pipeline runs end-to-end (pull → scan → patch → rescan → tag) but the final push to `localhost:8083` is a no-op so the workflow can be tested without a real registry.

---

## Table of Contents

- [How it works](#how-it-works)
- [Pipeline jobs](#pipeline-jobs)
- [Two-pass patching](#two-pass-patching)
- [Job summaries](#job-summaries)
- [Requirements](#requirements)
- [GitHub configuration](#github-configuration)
- [Running the pipeline](#running-the-pipeline)
- [Supported OS families](#supported-os-families)
- [Language-level package upgrades](#language-level-package-upgrades)
- [Scripts](#scripts)
- [Tests](tests.md)

---

## How it works

```
Docker Hub / Quay.io
        │
        ▼
┌─────────────────────────────────┐
│  Job 1 — CVE Scan               │
│  podman pull <image>            │
│  → .github/actions/trivy-scan   │
│    install Trivy                │
│    podman save → tar            │
│    trivy --exit-code 1          │
│    upload SARIF + JSON artifact │
└────────────────┬────────────────┘
                 │
    ┌────────────┴──────────────────────────┐
    │ clean (no CVEs)                       │ CVEs found
    │                                       ▼
    │               ┌────────────────────────────────────────────┐
    │               │ Job 2 — Patch Image (OS & Language pkg     │
    │               │         Update)                            │
    │               │ podman pull <image>                        │
    │               │ detect OS via /etc/os-release              │
    │               │ pass 1: apt-get / dnf / apk upgrade        │
    │               │ pass 2: targeted upgrade (Trivy JSON)      │
    │               │ pip / npm / mvn / go upgrade               │
    │               │ podman build --squash-all                  │
    │               │ upload patched-image artifact              │
    │               └─────────────────┬──────────────────────────┘
    │                                 │
    │                                 ▼
    │               ┌────────────────────────────────────────────┐
    │               │ Job 3 — CVE Rescan (Patched)               │
    │               │ download patched-image artifact            │
    │               │ → .github/actions/trivy-scan               │
    │               │   upload SARIF + JSON artifact (patched)   │
    │               │   Fixed CVEs section in summary            │
    │               └─────────────────┬──────────────────────────┘
    │                                 │
    │                    ┌────────────┴─────────────┐
    │                    │ clean                    │ CVEs remain
    │                    ▼                          ▼
    │            ┌───────────────────────┐   pipeline fails
    │            │ Job 4 — Publish to    │
    │            │         Registry      │
    │            │ resolve image:        │
    │            │  scan ok  → <tag>     │
    └──────────► │  rescan ok → <tag>-   │
                 │              patched  │
                 │ podman tag            │
                 │ # podman push (sim.)  │
                 └───────────────────────┘
```

---

## Pipeline jobs

| # | Job | Triggered when | What it does |
|---|---|---|---|
| 1 | **CVE Scan** | always | Pulls image; delegates scan to `.github/actions/trivy-scan` (install Trivy → save tar → scan → upload SARIF + JSON) |
| 2 | **Patch Image (OS & Language pkg Update)** | scan fails | Pulls image, detects OS, runs two-pass upgrade of OS packages and language runtimes, builds patched image with `--squash-all`, uploads tar artifact |
| 3 | **CVE Rescan (Patched)** | patch succeeds | Downloads patched image artifact, delegates scan to `.github/actions/trivy-scan`; summary includes Fixed CVEs comparison against original scan |
| 4 | **Publish to Registry** | scan passes OR rescan passes | Tags image for `localhost:8083`; login and push are commented out (simulated) |

> The scan logic lives once in `.github/actions/trivy-scan/action.yml` (composite action). Both Job 1 and Job 3 call it with different `image`, `tar_path`, and `artifact_name` inputs.

> Each job runs on a fresh GitHub managed runner — no shared filesystem between jobs. The patched image tar is passed between jobs via GitHub Actions artifacts.

---

## Two-pass patching

`patch-image.sh` runs two Dockerfile builds to maximise CVE coverage:

**Pass 1 — broad upgrade**
Runs the OS package manager upgrade across all packages (`apt-get upgrade`, `dnf upgrade --nobest --skip-broken`, `apk upgrade`). `--skip-broken` on DNF is needed for AI/GPU images with tight dependency pins.

**Pass 2 — targeted upgrade**
Trivy is installed if absent, then scans the pass-1 image in JSON mode. `jq` extracts the OS packages that still have a `FixedVersion`. A second Dockerfile is built targeting only those specific packages **without** `--skip-broken`, so individual packages get upgraded even when the broad upgrade skipped them.

If no remaining fixable packages are found after pass 1, pass 2 is skipped and the pass-1 result becomes the final image.

---

## Job summaries

Each job writes a Markdown summary visible in the **Summary** tab of the GitHub Actions run.

**CVE Scan / CVE Rescan (Patched)**

| Section | Description |
|---|---|
| Status | ✅ Passed / ❌ Failed with CVE count |
| Severity gate | The configured severity filter |
| Fixable CVEs | Table of packages with a fix available (Package, CVE, Severity, Installed, Fixed) |
| Not Fixable CVEs | Table of packages with no fix yet available |
| ✅ Fixed CVEs | *(Rescan only)* CVEs present in the original scan that are gone from the patched image |

**Publish to Registry**

Shows the source image, registry target, severity gate, and the simulated pull command.

---

## Requirements

| Requirement | Notes |
|---|---|
| GitHub managed runner | Workflow runs on `ubuntu-latest` — no self-hosted runner needed |
| Podman | Pre-installed on `ubuntu-latest` GitHub runners |
| Trivy | Installed automatically to `$HOME/.local/bin` by the composite action and by `patch-image.sh` when needed for the second pass |
| jq | Pre-installed on `ubuntu-latest` GitHub runners; used for Trivy JSON parsing |

---

## GitHub configuration

No repository variables are required.

### Secrets

Secrets are only needed when you uncomment the real `podman login` / `podman push` in the publish job. Go to **Settings → Secrets and variables → Actions** and add:

| Secret | Value | Used by |
|---|---|---|
| `NEXUS_USER` | Registry username | Job 4 — `podman login localhost:8083` |
| `NEXUS_PASSWORD` | Registry password | Job 4 — `podman login localhost:8083` |

> While login and push are simulated, these secrets are not used and do not need to be set.

---

## Running the pipeline

Go to **Actions → Scan and Publish Container Image → Run workflow** and fill in:

| Input | Description | Example |
|---|---|---|
| `registry` | Source registry | `docker.io` or `quay.io` |
| `image_name` | Image name including namespace | `library/ubuntu` or `redhat/granite-3-2b-instruct` |
| `tag` | Image tag | `latest` or `24.04` |
| `severity` | Minimum CVE severity that breaks the pipeline | `HIGH,CRITICAL` (default) |

### Severity options

| Option | Blocks on |
|---|---|
| `CRITICAL` | Critical CVEs only |
| `HIGH,CRITICAL` | High and critical (recommended default) |
| `MEDIUM,HIGH,CRITICAL` | Medium and above |

Only CVEs **with an available fix** are counted (`--ignore-unfixed`). Each run uploads SARIF and JSON scan reports as pipeline artifacts.

---

## Supported OS families

OS is detected by reading `/etc/os-release` via `podman create` + `podman cp` — **the container is never started**. This handles images that cannot run normally: AI model servers, GPU-only images, init-heavy images.

| OS family | Detected via `ID=` | Package manager | Update command | Notes |
|---|---|---|---|---|
| Ubuntu | `ubuntu` | `apt-get` | `apt-get upgrade -y` | — |
| Debian | `debian` | `apt-get` | `apt-get upgrade -y` | — |
| RHEL / CentOS / Rocky / AlmaLinux | `rhel` / `centos` / `rocky` / `almalinux` | `dnf` | `dnf upgrade -y` | `--nobest --skip-broken` in pass 1 |
| Oracle Linux | `ol` | `dnf` | `dnf upgrade -y` | `--nobest --skip-broken` in pass 1 |
| Fedora | `fedora` | `dnf` | `dnf upgrade -y` | `--nobest --skip-broken` in pass 1 |
| Amazon Linux | `amzn` | `dnf` | `dnf upgrade -y` | `--nobest --skip-broken` in pass 1 |
| Alpine | `alpine` | `apk` | `apk upgrade --no-cache` | — |
| openSUSE / SLES | `opensuse*` / `sles` | `zypper` | `zypper update -y` | — |

All packages are fetched from the upstream public repositories of each distribution.

**Why `--nobest --skip-broken` for DNF?**
Some packages in AI/GPU images have tight version-pinned dependencies that cannot be satisfied by the latest versions. `--nobest` allows DNF to fall back to an older compatible version; `--skip-broken` drops any package it cannot resolve rather than failing the entire transaction. The second pass then retries the skipped packages individually.

---

## Language-level package upgrades

After the OS package update, `patch-image.sh` appends a best-effort upgrade block for language runtimes. Each section is a no-op when the toolchain is absent from the image — no toolchain is installed if missing.

| Runtime | Detected via | What is upgraded | Source |
|---|---|---|---|
| Python | `pip3` | All outdated packages (`pip3 list --outdated` → `pip3 install -U`); pip itself is upgraded first | PyPI |
| Node.js | `npm` | Global packages (`npm update -g`); cache purged after | npm registry |
| Node.js | `yarn` | Global packages (`yarn global upgrade`); cache purged after | yarn registry |
| Java | `mvn` | Dependency versions in any `pom.xml` found in the image (`versions:use-latest-releases`) | Maven Central |
| Go binaries | `go` | Each Go binary is inspected for its embedded module path (`go version -m`) and rebuilt via `go install <path>@latest` | proxy.golang.org |

> **Go binaries without a toolchain** (e.g. pre-compiled `pebble`, `mongodump`): these cannot be upgraded by package managers because the vulnerable modules are compiled into the binary. Trivy reports them under type `gobinary`. The only fix is an upstream rebuild.

---

## Scripts

### patch-image.sh

Detects the OS inside a container image (without starting it), generates an OS-specific update script using public repositories, and builds the patched image using two passes.

```bash
# Syntax
bash patch-image.sh <source_image> <output_image>

# Examples
bash patch-image.sh docker.io/library/ubuntu:24.04 ubuntu:24.04-patched
bash patch-image.sh docker.io/library/mongo:latest mongo:latest-patched
bash patch-image.sh docker.io/redhat/ubi9:latest ubi9:latest-patched
```

No environment variables or credentials are required — all package sources are public.

**lib/ directory**

| File | Purpose |
|---|---|
| `lib/detect-os.sh` | Reads `/etc/os-release` from the image without starting the container; exports `OS_ID`, `OS_VERSION`, `ORIGINAL_USER` |
| `lib/os-packages.sh` | Generates OS-specific update scripts; maps OS IDs to Trivy result types for the second pass |
| `lib/lang-packages.sh` | Appends language-runtime upgrade blocks (Python, Node.js, Java, Go) |
| `lib/second-pass.sh` | Installs Trivy if absent, scans the pass-1 image, extracts remaining fixable packages, and builds a targeted second-pass image |

### check-os.sh

Inspects a predefined list of images, detects the OS and installed language runtimes, and generates ready-to-use Dockerfiles under `updated/`.

```bash
./check-os.sh
```

---

## Tests

See [tests.md](tests.md) for the full test image matrix and instructions on running and collecting pipeline test results.
