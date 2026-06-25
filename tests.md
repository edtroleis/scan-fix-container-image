# Tests

## Table of Contents

- [Pipeline run summary (HIGH,CRITICAL)](#pipeline-run-summary-highcritical)
- [Pipeline run summary (CRITICAL only)](#pipeline-run-summary-critical-only)
- [Test images](#test-images)
- [Severity comparison](#severity-comparison)
- [Test pipeline workflow](#test-pipeline-workflow)

---

## Pipeline run summary (HIGH,CRITICAL)

<!-- run-stats-hc:start -->
> **Run date:** 2026-06-25 17:34 UTC — **Severity gate:** `HIGH,CRITICAL`

| Metric | Count | Rate |
|--------|------:|-----:|
| **Total images tested** | 40 | — |
| **No CVEs (approved without patch)** | 10 | 25.0% |
| **CVEs found** | 30 | — |
| ↳ Patched & approved | 10 | 25.0% |
| ↳ Rejected (CVEs remain) | 20 | 50.0% |
<!-- run-stats-hc:end -->

---

## Pipeline run summary (CRITICAL only)

<!-- run-stats-c:start -->
> _Not yet run — execute `./run-pipeline-tests.sh` to populate._
<!-- run-stats-c:end -->

---

## Test images

| # | Registry | Image name | Tag | Type | Category | Result (HIGH,CRITICAL) | Result (CRITICAL) |
|---|---|---|---|---|---|---|---|
| 1 | `docker.io` | `library/ubuntu` | `22.04` | Official | Base OS — Ubuntu LTS (older) | ✅ Patched (CVEs fixed) | — |
| 2 | `docker.io` | `library/ubuntu` | `24.04` | Official | Base OS — Ubuntu LTS (current) | ✅ Patched (CVEs fixed) | — |
| 3 | `docker.io` | `library/debian` | `bullseye` | Official | Base OS — Debian 11 (older) | ✅ Passed (no CVEs) | — |
| 4 | `docker.io` | `library/debian` | `bookworm-slim` | Official | Base OS — Debian 12 slim | ✅ Passed (no CVEs) | — |
| 5 | `docker.io` | `library/alpine` | `3.19` | Official | Base OS — Alpine (minimal) | ✅ Patched (CVEs fixed) | — |
| 6 | `docker.io` | `library/amazonlinux` | `2023` | Official | Base OS — Amazon Linux 2023 (DNF) | ❌ Failed (CVEs remain) | — |
| 7 | `docker.io` | `library/fedora` | `40` | Official | Base OS — Fedora (DNF) | ❌ Failed (CVEs remain) | — |
| 8 | `docker.io` | `library/python` | `3.11-bullseye` | Official | Language — Python on Debian 11 | ❌ Failed (CVEs remain) | — |
| 9 | `docker.io` | `library/python` | `3.12-slim` | Official | Language — Python slim | ✅ Passed (no CVEs) | — |
| 10 | `docker.io` | `library/node` | `20-slim` | Official | Language — Node.js slim | ❌ Failed (CVEs remain) | — |
| 11 | `docker.io` | `library/node` | `18-alpine` | Official | Language — Node.js on Alpine | ❌ Failed (CVEs remain) | — |
| 12 | `docker.io` | `library/golang` | `1.22-alpine` | Official | Language — Go on Alpine | ✅ Patched (CVEs fixed) | — |
| 13 | `docker.io` | `library/nginx` | `1.26-alpine` | Official | Web server — Nginx on Alpine | ✅ Patched (CVEs fixed) | — |
| 14 | `docker.io` | `library/httpd` | `2.4` | Official | Web server — Apache | ✅ Passed (no CVEs) | — |
| 15 | `docker.io` | `library/postgres` | `15` | Official | Database — PostgreSQL 15 | ❌ Failed (CVEs remain) | — |
| 16 | `docker.io` | `library/mysql` | `8.0` | Official | Database — MySQL 8.0 | ❌ Failed (CVEs remain) | — |
| 17 | `docker.io` | `library/redis` | `7-alpine` | Official | Cache — Redis 7 on Alpine | ✅ Passed (no CVEs) | — |
| 18 | `docker.io` | `library/mariadb` | `11` | Official | Database — MariaDB 11 | ✅ Patched (CVEs fixed) | — |
| 19 | `docker.io` | `library/rabbitmq` | `3-alpine` | Official | Message broker — RabbitMQ | ✅ Patched (CVEs fixed) | — |
| 20 | `docker.io` | `library/traefik` | `v3.2` | Official | Reverse proxy (gobinary CVEs expected) | ❌ Failed (CVEs remain) | — |
| 21 | `docker.io` | `library/redis` | `6.2-alpine` | Official | Cache — Redis 6.2 (older) | ✅ Passed (no CVEs) | — |
| 22 | `docker.io` | `library/redis` | `7.0-alpine` | Official | Cache — Redis 7.0 | ✅ Patched (CVEs fixed) | — |
| 23 | `docker.io` | `library/redis` | `7.4-alpine` | Official | Cache — Redis 7.4 | ✅ Passed (no CVEs) | — |
| 24 | `docker.io` | `library/mongo` | `6` | Official | Database — MongoDB 6 | ❌ Failed (CVEs remain) | — |
| 25 | `docker.io` | `library/mongo` | `7` | Official | Database — MongoDB 7 | ❌ Failed (CVEs remain) | — |
| 26 | `docker.io` | `library/mongo` | `8` | Official | Database — MongoDB 8 | ❌ Failed (CVEs remain) | — |
| 27 | `docker.io` | `prom/prometheus` | `v2.53.0` | Verified | Observability — Prometheus | ❌ Failed (CVEs remain) | — |
| 28 | `docker.io` | `grafana/grafana` | `11.1.0` | Verified | Observability — Grafana | ❌ Failed (CVEs remain) | — |
| 29 | `docker.io` | `grafana/loki` | `3.1.0` | Verified | Observability — Loki (log aggregation) | ❌ Failed (CVEs remain) | — |
| 30 | `docker.io` | `grafana/tempo` | `2.5.0` | Verified | Observability — Tempo (distributed tracing) | ❌ Failed (CVEs remain) | — |
| 31 | `docker.io` | `jaegertracing/all-in-one` | `1.60` | Verified | Observability — Jaeger tracing | ❌ Failed (CVEs remain) | — |
| 32 | `docker.io` | `library/influxdb` | `2.7-alpine` | Official | Observability — InfluxDB time series | ❌ Failed (CVEs remain) | — |
| 33 | `docker.io` | `library/memcached` | `alpine` | Official | Cache — Memcached | ✅ Passed (no CVEs) | — |
| 34 | `docker.io` | `library/wordpress` | `php8.3-apache` | Official | CMS — WordPress | ✅ Passed (no CVEs) | — |
| 35 | `docker.io` | `library/nginx` | `mainline-alpine` | Official | Web server — Nginx mainline | ✅ Passed (no CVEs) | — |
| 36 | `docker.io` | `library/postgres` | `16-alpine` | Official | Database — PostgreSQL 16 Alpine | ✅ Patched (CVEs fixed) | — |
| 37 | `docker.io` | `library/mysql` | `9.0` | Official | Database — MySQL 9.0 | ❌ Failed (CVEs remain) | — |
| 38 | `docker.io` | `library/cassandra` | `5` | Official | Database — Cassandra 5 | ❌ Failed (CVEs remain) | — |
| 39 | `docker.io` | `library/sonarqube` | `community` | Official | Code quality — SonarQube | ❌ Failed (CVEs remain) | — |
| 40 | `docker.io` | `library/rabbitmq` | `3.13-management-alpine` | Official | Message broker — RabbitMQ with UI | ✅ Patched (CVEs fixed) | — |

> **Result key:** ✅ Passed — scan found no CVEs at configured severity / ✅ Patched — scan failed but rescan after patching passed / ❌ Failed — CVEs remain after patching (gobinary or no fix available) / — not yet tested

---

## Severity comparison

<!-- run-compare:start -->
> _Not yet run — execute `./run-pipeline-tests.sh` to populate._
<!-- run-compare:end -->

---

## Test pipeline workflow

### run-pipeline-tests.sh

Triggers the scan-and-publish workflow for all 40 test images (or a subset) with **both**
`HIGH,CRITICAL` and `CRITICAL` severity gates, waits for all runs to complete, prints a
summary, and updates `tests.md` with results, statistics, and a severity comparison.

```bash
# Syntax
./run-pipeline-tests.sh [from] [to]

# Examples
./run-pipeline-tests.sh                           # all 40 images, both severity sets
./run-pipeline-tests.sh 1 10                      # images #1–#10 only
DELAY=10 POLL=30 TIMEOUT=45 ./run-pipeline-tests.sh
```

Output files:
- `pipeline-runs-results-hc.tsv` — HIGH,CRITICAL results
- `pipeline-runs-results-c.tsv` — CRITICAL results

**Result values written to tests.md:**

| Result | Meaning |
|---|---|
| ✅ Passed (no CVEs) | Scan found no fixable CVEs at configured severity |
| ✅ Patched (CVEs fixed) | CVEs were found, patched, and rescan passed |
| ❌ Failed (CVEs remain) | CVEs were found, patched, but rescan still failed |
| ❌ Failed (patch error) | Patch job itself failed |
| ❌ Failed (scan error) | Scan job failed for a reason other than CVEs |
| ⏱️ Timeout | Run did not complete within the timeout window |
| — | Run was not triggered |
