# internalize-container-image

Scan public container images for CVEs and publish them to a private Nexus registry. When CVEs are found, the pipeline automatically patches the image by updating OS packages through local Nexus proxy repositories, rescans, and only publishes if it passes.

---

## Table of Contents

- [How it works](#how-it-works)
- [Pipeline jobs](#pipeline-jobs)
- [Requirements](#requirements)
- [GitHub configuration](#github-configuration)
- [Nexus configuration](#nexus-configuration)
- [Running the pipeline](#running-the-pipeline)
- [Supported OS families](#supported-os-families)
- [Security model](#security-model)
- [Scripts](#scripts)

---

## How it works

```
                 ┌─────────────────────────────────────────────┐
                 │           GitHub Actions Workflow            │
                 │         (self-hosted runner + Podman)        │
                 └──────────────┬──────────────────────────────┘
                                │  workflow_dispatch trigger
                                ▼
                  ┌─────────────────────────────────┐
                  │  Job 1 — CVE Scan                │
                  │  podman pull <image>             │
                  │  → .github/actions/trivy-scan    │
                  │    install Trivy                 │
                  │    podman save → tar             │
                  │    trivy --exit-code 1           │
                  │    upload SARIF artifact         │
                  └────────────────┬────────────────┘
                                   │
              ┌────────────────────┴──────────────────────┐
              │ clean (no CVEs)                            │ CVEs found
              │                                            ▼
              │                       ┌───────────────────────────────────┐
              │                       │ Job 2 — Patch (OS Update)         │
              │                       │ podman pull <image>               │
              │                       │ detect OS via /etc/os-release     │
              │                       │ generate OS-specific update       │
              │                       │ podman build --secret             │
              │                       │   --squash-all --network=host     │
              │                       └─────────────────┬─────────────────┘
              │                                         │
              │                                         ▼
              │                       ┌───────────────────────────────────┐
              │                       │ Job 3 — CVE Rescan (Patched)      │
              │                       │ → .github/actions/trivy-scan      │
              │                       │   (same action, patched image)    │
              │                       │   upload SARIF artifact (patched) │
              │                       └─────────────────┬─────────────────┘
              │                                         │
              │                            ┌────────────┴────────────┐
              │                            │ clean                    │ CVEs remain
              ▼                            ▼                          ▼
              └────────────────► ┌──────────────────────┐   pipeline fails
                                 │ Job 4 — Publish       │
                                 │ resolve image:        │
                                 │  scan ok → <tag>      │
                                 │  rescan ok → <tag>-   │
                                 │             patched   │
                                 │ podman tag + push     │
                                 └──────────────────────┘
```

---

## Pipeline jobs

| # | Job | Triggered when | What it does |
|---|---|---|---|
| 1 | **CVE Scan** | always | Pulls image; delegates scan to `.github/actions/trivy-scan` (install Trivy → save tar → scan → upload SARIF) |
| 2 | **Patch** | scan fails | Pulls image, detects OS, updates packages via Nexus proxy, builds patched image |
| 3 | **CVE Rescan** | patch succeeds | Delegates scan to `.github/actions/trivy-scan` — same action, patched image |
| 4 | **Publish** | scan passes OR rescan passes | Resolves which image to push at runtime: original `<tag>` when scan passed, `<tag>-patched` when rescan passed |

> The scan logic lives once in `.github/actions/trivy-scan/action.yml` (composite action). Both Job 1 and Job 3 call it with different `image`, `tar_path`, and `artifact_name` inputs.

> Job 2 pulls the image explicitly even though job 1 already pulled it. Podman storage is persistent across jobs on a self-hosted runner, but the pull ensures the image is available if storage was evicted or the runner was restarted between jobs.

---

## Requirements

| Requirement | Notes |
|---|---|
| Self-hosted GitHub Actions runner | Must run on the same machine as Nexus — GitHub-hosted runners cannot reach `localhost` |
| Podman 4+ | Required for `--secret` and `--squash-all` support |
| Nexus Repository Manager 3 | With package proxy repos and a Docker hosted registry |
| Trivy | Installed automatically on the first run if not present |

---

## GitHub configuration

Go to **Settings → Secrets and variables → Actions** and add:

### Secrets

| Secret | Value | Used by |
|---|---|---|
| `NEXUS_USER` | Nexus username (e.g. `github-actions`) | Docker push (jobs 2, 5) + package proxy auth (job 3) |
| `NEXUS_PASSWORD` | Nexus password for that user | Same |

### Variables

| Variable | Example value | Used by |
|---|---|---|
| `NEXUS_HOST` | `localhost:8081` | Job 3 — Nexus API / package proxy base URL |
| `NEXUS_HOST_EXTERNAL_IMAGES` | `localhost:8083` | Jobs 2, 5 — Docker registry URL for `podman login` and `podman push` |

> Variables are plain text and visible in build logs. Use them for non-sensitive values like hostnames and ports. Credentials always go in Secrets.

### Nexus user requirements

The Nexus user referenced by `NEXUS_USER` must have **both** of these roles:

| Role | Why |
|---|---|
| `docker-publisher` | `podman push` to the `external-images` Docker registry |
| `repo-reader` | Download packages from proxy repos during the patch step |

---

## Nexus configuration

The patch gate routes all package downloads through Nexus proxy repositories. The following repos must exist:

### RPM repos (one group per OS family)

Each group contains only packages compatible with its target OS, preventing DNF from mixing `el9` (RHEL) and `fc43` (Fedora) package versions.

| Group | Format | Members | Used for |
|---|---|---|---|
| `repo-rpm-rhel` | yum group | `repo-rpm-rhel-baseos` + `repo-rpm-rhel-appstream` | RHEL / CentOS / Rocky / AlmaLinux |
| `repo-rpm-fedora` | yum group | `repo-rpm-fedora-releases` + `repo-rpm-fedora-updates` | Fedora |
| `repo-rpm-amz` | yum group | `repo-rpm-local` + all of the above | Amazon Linux |

### APT and Alpine repos

| Repository | Format | Used for |
|---|---|---|
| `repo-apt-ubuntu-proxy` | apt proxy → Ubuntu 24.04 noble | Ubuntu containers |
| `repo-apt-debian-proxy` | apt proxy → Debian 12 bookworm | Debian containers |
| `repo-apk` | raw group → Alpine CDN | Alpine containers |

### Go repo

| Repository | Format | Members | Used for |
|---|---|---|---|
| `repo-go-hosted` | go hosted | — | Local/private Go modules |
| `repo-go-proxy` | go proxy → `proxy.golang.org` | — | Public Go modules |
| `repo-go` | go group | `repo-go-hosted` + `repo-go-proxy` | `GOPROXY` target during `go install` in the patch step |

Client usage: `GOPROXY=http://<NEXUS_HOST>:8081/repository/repo-go,direct`

### Docker registry

| Repository | Port | Used for |
|---|---|---|
| `external-images` | `NEXUS_HOST_EXTERNAL_IMAGES` (e.g. `8083`) | `podman push` target for all published images |

See [nexus-repository](../nexus-repository) for automated setup of all repositories.

### Allow insecure registry (Podman)

Add to `/etc/containers/registries.conf` on the runner machine, using the hostname:port from `NEXUS_HOST_EXTERNAL_IMAGES`:

```ini
[[registry]]
location = "localhost:8083"
insecure = true
```

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

The pipeline is safe to re-run: existing `/tmp/source-image.tar` and `/tmp/patched-image.tar` files are removed before each `podman save` to avoid the `docker-archive doesn't support modifying existing images` error.

---

## Supported OS families

OS is detected by reading `/etc/os-release` via `podman create` + `podman cp` — **the container is never started**. This handles images that cannot run normally: AI model servers, GPU-only images, init-heavy images.

| OS family | Detected via `ID=` | Package manager | Nexus repo | DNF flags |
|---|---|---|---|---|
| Ubuntu | `ubuntu` | `apt-get` | `repo-apt-ubuntu-proxy` | — |
| Debian | `debian` | `apt-get` | `repo-apt-debian-proxy` | — |
| RHEL / CentOS / Rocky / AlmaLinux | `rhel` / `centos` / `rocky` / `almalinux` | `dnf` | `repo-rpm-rhel` | `--disablerepo='*'` `--nobest` `--skip-broken` |
| Fedora | `fedora` | `dnf` | `repo-rpm-fedora` | `--disablerepo='*'` `--nobest` `--skip-broken` |
| Amazon Linux | `amzn` | `dnf` | `repo-rpm-amz` | `--nobest` `--skip-broken` |
| Alpine | `alpine` | `apk` | `repo-apk` | `--allow-untrusted` |
| openSUSE / SLES | `opensuse*` / `sles` | `zypper` | native repos | — |

**Why `--disablerepo='*'` for RHEL and Fedora?**
AI model and GPU images often ship with EPEL, Copr, and vendor repos pre-configured. These repos introduce `el9` or `fc43` packages that conflict with each other when mixed. Disabling all repos except the dedicated Nexus group ensures DNF only sees one package universe.

**Why `--nobest --skip-broken`?**
Some packages in AI/GPU images have tight version-pinned dependencies (e.g. `spirv-tools-libs = 2024.2`) that cannot be satisfied by the versions in UBI repos. `--nobest` allows DNF to skip to an older compatible version; `--skip-broken` drops any package it cannot resolve rather than failing the entire transaction.

---

## Language-level package upgrades

After the OS package update, `patch-image.sh` appends a best-effort upgrade block for language runtimes. Each section is a no-op when the toolchain is absent from the image — no toolchain is installed if missing.

| Runtime | Detected via | What is upgraded |
|---|---|---|
| Python | `pip3` | All outdated packages (`pip3 list --outdated` → `pip3 install -U`); pip itself is upgraded first |
| Node.js | `npm` | Global packages (`npm update -g`); cache is purged after |
| Node.js | `yarn` | Global packages (`yarn global upgrade`); cache is purged after |
| Java | `mvn` | Dependency versions in any `pom.xml` found in the image (`versions:use-latest-releases`) |
| Go binaries | `go` | Each Go binary is inspected for its embedded module path (`go version -m`) and rebuilt via `go install <path>@latest` routed through `GOPROXY=http://<NEXUS_HOST>/repository/repo-go,direct` |

> **Go binaries without a toolchain** (e.g. pre-compiled `mongodump`, `mongotop`): these cannot be upgraded at the OS layer if the vendor has not yet released a fixed version — Trivy shows `-` in the *Fixed* column. The Go upgrade block only runs when the Go toolchain is present inside the image itself. In that case, `go install @latest` fetches and rebuilds each binary from its module path.

---

## Security model

Nexus credentials are never written to the Dockerfile, never appear in build logs, and never enter an image layer.

```
GitHub Secrets
  NEXUS_USER      ──► env NEXUS_USER      ┐
  NEXUS_PASSWORD  ──► env NEXUS_PASSWORD  │  patch-image.sh
                                          │
                                          ▼
               printf 'user:pass' > $TMPDIR/nexus_creds  (chmod 600)
               podman build --secret id=nexus_creds,src=$TMPDIR/nexus_creds
                                          │
                        ┌─────────────────┘
                        │  Inside RUN step only
                        ▼
              /run/secrets/nexus_creds  (tmpfs — never a layer)
              CREDS=$(cat /run/secrets/nexus_creds)
              AUTH="user:pass@"  →  http://user:pass@localhost:8081/repository/...
              dnf / apt-get / apk  →  Nexus proxy
              rm /etc/yum.repos.d/nexus-*.repo
                        │
              podman build --squash-all
                        │
                        ▼
              Final image: no credentials, no repo config, single squashed layer
```

| Mechanism | What it protects |
|---|---|
| `--secret id=nexus_creds` | Credentials mounted as tmpfs — visible only in the RUN step, not written to any image layer |
| `--squash-all` | Merges all layers into one — intermediate filesystem state (repo files, cache) does not appear in image history |
| `--network=host` | RUN steps can reach `localhost:8081` (Nexus on the host machine) |
| `--disablerepo='*'` | Isolates DNF to the Nexus repo only — no external DNS lookups, no mixed package sources |
| `rm nexus-*.repo` (in RUN) | Repo config file is deleted within the same RUN step that created it — never in the final layer |
| `rm -f /tmp/run-update.sh` (in RUN) | Uses `-f` because Debian/Ubuntu update scripts clean `/tmp/*` during package upgrade — the file may already be gone when the Dockerfile's cleanup runs |

---

## Scripts

### patch-image.sh

Detects the OS inside a container image (without starting it), generates an OS-specific update script, passes Nexus credentials as a build secret, and builds the patched image.

```bash
# Syntax
bash patch-image.sh <source_image> <output_image>

# Required environment variables
NEXUS_HOST=localhost:8081       # defaults to localhost:8081 if unset
NEXUS_USER=github-actions
NEXUS_PASSWORD=secret

# Local use
NEXUS_USER=alice NEXUS_PASSWORD=secret \
  bash patch-image.sh docker.io/library/ubuntu:24.04 ubuntu:24.04-patched

# RHEL UBI image (no credentials needed for public UBI repos)
bash patch-image.sh docker.io/redhat/ubi9:latest ubi9:latest-patched
```

### check-os.sh

Inspects images defined in the script, detects the OS and installed runtimes, and generates ready-to-use Dockerfiles under `updated/`.

```bash
./check-os.sh
```
