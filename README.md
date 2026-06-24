# scan-fix-container-image

Scan public container images for CVEs using Trivy and publish approved images to a container registry. When CVEs are found the pipeline automatically patches the image by updating OS and language-runtime packages from public repositories, rescans, and only publishes if the patched image passes.

> **Simulated registry:** `podman push` is commented out in the publish job. The pipeline runs end-to-end (pull → scan → patch → rescan → tag) but the final push to `localhost:8083` is a no-op so the workflow can be tested without a real registry.

---

## Table of Contents

- [How it works](#how-it-works)
- [Pipeline jobs](#pipeline-jobs)
- [Requirements](#requirements)
- [GitHub configuration](#github-configuration)
- [Running the pipeline](#running-the-pipeline)
- [Supported OS families](#supported-os-families)
- [Language-level package upgrades](#language-level-package-upgrades)
- [Scripts](#scripts)

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
│    upload SARIF artifact        │
└────────────────┬────────────────┘
                 │
    ┌────────────┴────────────────────┐
    │ clean (no CVEs)                  │ CVEs found
    │                                  ▼
    │               ┌───────────────────────────────────┐
    │               │ Job 2 — Patch Image (OS Update)    │
    │               │ podman pull <image>               │
    │               │ detect OS via /etc/os-release     │
    │               │ apt-get / dnf / apk upgrade       │
    │               │ pip / npm / mvn / go upgrade      │
    │               │ podman build --squash-all         │
    │               └─────────────────┬─────────────────┘
    │                                 │
    │                                 ▼
    │               ┌───────────────────────────────────┐
    │               │ Job 3 — CVE Rescan (Patched)       │
    │               │ → .github/actions/trivy-scan       │
    │               │   (same action, patched image)    │
    │               │   upload SARIF artifact (patched) │
    │               └─────────────────┬─────────────────┘
    │                                 │
    │                    ┌────────────┴────────────┐
    │                    │ clean                    │ CVEs remain
    ▼                    ▼                          ▼
    └──────────► ┌──────────────────────┐   pipeline fails
                 │ Job 4 — Publish       │
                 │ resolve image:        │
                 │  scan ok  → <tag>     │
                 │  rescan ok → <tag>-   │
                 │              patched  │
                 │ podman tag            │
                 │ # podman push (sim.)  │
                 └──────────────────────┘
```

---

## Pipeline jobs

| # | Job | Triggered when | What it does |
|---|---|---|---|
| 1 | **CVE Scan** | always | Pulls image; delegates scan to `.github/actions/trivy-scan` (install Trivy → save tar → scan → upload SARIF) |
| 2 | **Patch** | scan fails | Pulls image, detects OS, upgrades OS packages and language runtimes from public repos, builds patched image with `--squash-all` |
| 3 | **CVE Rescan** | patch succeeds | Delegates scan to `.github/actions/trivy-scan` — same composite action, patched image |
| 4 | **Publish** | scan passes OR rescan passes | Tags image for `localhost:8083`; push is commented out (simulated) |

> The scan logic lives once in `.github/actions/trivy-scan/action.yml` (composite action). Both Job 1 and Job 3 call it with different `image`, `tar_path`, and `artifact_name` inputs.

> Job 2 pulls the image explicitly because GitHub managed runners start with a clean environment — the image pulled in Job 1 is not available to subsequent jobs.

---

## Requirements

| Requirement | Notes |
|---|---|
| GitHub managed runner | Workflow runs on `ubuntu-latest` — no self-hosted runner needed |
| Podman | Pre-installed on `ubuntu-latest` GitHub runners |
| Trivy | Installed automatically to `$HOME/.local/bin` on the first run |

---

## GitHub configuration

Go to **Settings → Secrets and variables → Actions** and add:

### Secrets

| Secret | Value | Used by |
|---|---|---|
| `NEXUS_USER` | Registry username | Job 4 — `podman login localhost:8083` |
| `NEXUS_PASSWORD` | Registry password | Job 4 — `podman login localhost:8083` |

> No repository variables are required. The registry address (`localhost:8083`) is hardcoded in the workflow.

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

Only CVEs **with an available fix** are counted (`--ignore-unfixed`). Trivy scan reports (SARIF format) are uploaded as pipeline artifacts on every run, including failures.

---

## Supported OS families

OS is detected by reading `/etc/os-release` via `podman create` + `podman cp` — **the container is never started**. This handles images that cannot run normally: AI model servers, GPU-only images, init-heavy images.

| OS family | Detected via `ID=` | Package manager | Update command | DNF flags |
|---|---|---|---|---|
| Ubuntu | `ubuntu` | `apt-get` | `apt-get upgrade -y` | — |
| Debian | `debian` | `apt-get` | `apt-get upgrade -y` | — |
| RHEL / CentOS / Rocky / AlmaLinux | `rhel` / `centos` / `rocky` / `almalinux` | `dnf` | `dnf upgrade -y` | `--nobest` `--skip-broken` |
| Fedora | `fedora` | `dnf` | `dnf upgrade -y` | `--nobest` `--skip-broken` |
| Amazon Linux | `amzn` | `dnf` | `dnf upgrade -y` | `--nobest` `--skip-broken` |
| Alpine | `alpine` | `apk` | `apk upgrade --no-cache` | — |
| openSUSE / SLES | `opensuse*` / `sles` | `zypper` | `zypper update -y` | — |

All packages are fetched directly from the upstream public repositories of each distribution.

**Why `--nobest --skip-broken` for DNF?**
Some packages in AI/GPU images have tight version-pinned dependencies that cannot be satisfied by the latest versions. `--nobest` allows DNF to fall back to an older compatible version; `--skip-broken` drops any package it cannot resolve rather than failing the entire transaction.

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

> **Go binaries without a toolchain** (e.g. pre-compiled `mongodump`, `mongotop`): these cannot be upgraded if the vendor has not yet released a fixed version — Trivy shows `-` in the *Fixed* column. The Go upgrade block only runs when the Go toolchain is present inside the image itself.

---

## Scripts

### patch-image.sh

Detects the OS inside a container image (without starting it), generates an OS-specific update script using public repositories, and builds the patched image.

```bash
# Syntax
bash patch-image.sh <source_image> <output_image>

# Examples
bash patch-image.sh docker.io/library/ubuntu:24.04 ubuntu:24.04-patched
bash patch-image.sh docker.io/library/mongo:latest mongo:latest-patched
bash patch-image.sh docker.io/redhat/ubi9:latest ubi9:latest-patched
```

No environment variables or credentials are required — all package sources are public.

### check-os.sh

Inspects a predefined list of images, detects the OS and installed language runtimes, and generates ready-to-use Dockerfiles under `updated/`.

```bash
./check-os.sh
```
