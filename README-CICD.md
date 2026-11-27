# GLPI 12 — Jenkins CI/CD

Vendor model: we ship **upstream GLPI releases**, not a fork. CI therefore proves the
things upstream's CI cannot: that *our* image, *our* chart and *our* database version
work together. No 60-minute PHP test matrix — that would only re-prove upstream's
own tests.

```
GLPI tag ──► Jenkins ──► glpi-php / glpi-web images ──► registry
                                                          │
                          commit new tag to GitOps repo ◄─┘
                                        │
                                     ArgoCD ──► k3s
                                        │
                            pre-sync Job: database:update
```

Jenkins never talks to the cluster. It publishes an immutable image and a Git commit;
ArgoCD stays the only writer. Rollback = `git revert`.

## Repositories

Three public repos, all under `MohamedBakrim`:

| Repo | Holds | Jenkins touches it? |
|---|---|---|
| [`glpi-app-cicd`](https://github.com/MohamedBakrim/glpi-app-cicd) | this pipeline: `Dockerfile`, `Jenkinsfile`, `ci/`, `nginx/`, `jenkins/` | yes — it is the multibranch source |
| [`glpi-chart-cicd`](https://github.com/MohamedBakrim/glpi-chart-cicd) | the Helm chart (fresh copy; nginx fixed to listen on 8080) | no — ArgoCD renders it |
| [`glpi-gitops-cicd`](https://github.com/MohamedBakrim/glpi-gitops-cicd) | `values-prod.yaml` + the ArgoCD Application | yes — `bump.sh` commits digest tags here |

The older `glpi-itsm-helm-chart` and `glpi-gitops` repos are intentionally not
used by this pipeline.

```
glpi-app-cicd ──build/push──► Docker Hub
      │                          │
      │ bump digest              │ pull
      ▼                          ▼
glpi-gitops-cicd ──ArgoCD──► k3s ◄── glpi-chart-cicd (renders)
```

## Layout

```
Dockerfile                 glpi-php-fpm (php-fpm) + glpi-nginx targets
nginx/nginx.conf           base config: /tmp paths, includes conf.d
nginx/default.conf         default vhost (listen 8080); chart replaces it via ConfigMap
Jenkinsfile                orchestration only — no logic
ci/config.sh               shared defaults (local runs)
ci/prepare.sh              fail fast: tools, upstream tag, checksum, cache
ci/build.sh                builds both targets with pinned checksum
ci/smoke.sh                cold install + boot + HTTP assertions + contract checks
ci/docker-compose.test.yml throwaway MariaDB stack
ci/scan.sh                 trivy gate (HIGH/CRITICAL, fixable only)
ci/publish.sh              push immutable tags, record manifest digests
ci/bump.sh                 digest-pinned tag bump in the GitOps repo
ci/verify.sh               argocd app wait + edge HTTP check
ci/cleanup.sh              always: down, drop secrets, prune
ci/pin-version.sh          pin an upstream archive checksum
ci/glpi.sha256             pinned versions
docker/                    (TODO) the five glpi-*.sh hook scripts the chart calls
jenkins/                   controller image + compose (docker socket)
```

## 1. Prepare the controller

The pipeline needs `docker`, `docker compose`, `yq` and `argocd` next to Jenkins:

```bash
cd jenkins
echo "DOCKER_GID=$(getent group docker | cut -d: -f3)" > .env
docker compose up -d --build
docker exec -u jenkins jenkins docker version
docker exec -u jenkins jenkins docker compose version
```

Required plugins: **Git**, **GitHub Branch Source**, **Pipeline**, **Credentials Binding**.
Everything else is plain `sh`.

> **Security note.** Mounting `/var/run/docker.sock` makes the Jenkins container
> equivalent to root on the host, and any PR that can edit a `Jenkinsfile` can use it.
> Acceptable for a homelab/portfolio cluster with trusted contributors. Before exposing
> this to outside PRs, move building to **kaniko/buildkit rootless** in a dedicated agent
> pod (only `ci/build.sh` changes), or give the controller a separate build agent VM.

## 2. Credentials

| ID | Kind | Used by | Notes |
|---|---|---|---|
| `registry-creds` | username/password | `publish.sh` | GHCR: GitHub user + PAT with `write:packages` |
| `gitops-token` | secret text | `bump.sh` | PAT with `contents:write` on the GitOps repo |
| `argocd-token` | secret text | `verify.sh` | optional; omit and the stage skips itself |

## 3. Job

* New Item → **Multibranch Pipeline** → Git → this repository.
* Build configuration: by `Jenkinsfile`.
* Scan triggers: **GitHub hook trigger** (`POST http://jenkins:8080/github-webhook/`)
  plus *Periodically if not otherwise run* (5 min) as a safety net.

Behaviour:

| Build | Build + smoke + scan | Publish | GitOps bump | Verify |
|---|---|---|---|---|
| pull request | ✅ | ❌ | ❌ | ❌ |
| `main` | ✅ | ✅ | ✅ | ✅ |

## 4. GitOps contract

This matches the chart in `MohamedBakrim/glpi-chart-cicd`, which keeps
the app and web images in two blocks:

```yaml
image:                       # php-fpm   → .image.repository / .image.tag
  repository: mdbak/glpi-php-fpm
  tag: "12.0.2@sha256:..."   # digest-pinned, as the chart already does
nginx:
  image:                     # → .nginx.image.repository / .nginx.image.tag
    repository: mdbak/glpi-nginx
    tag: "12.0.2@sha256:..."
```

`publish.sh` records each manifest digest in `.ci-out/digests.env`; `bump.sh` writes
`<version>@sha256:<digest>`. A moved or re-pushed tag therefore cannot change what the
cluster runs — only a new Git commit can.

`GITOPS_VALUES_FILE` points at the values file ArgoCD actually reads. In the
`glpi-gitops-cicd` repo that is `values-prod.yaml` at the repo root, and
`argocd/application.yaml` wires it into the chart as a second source (`$values`).

ArgoCD application must run with automated sync + `selfHeal: true`. The chart owns the
migration chain (`verify-dir` → `db-install`/`db-upgrade` → `configure` → `cache`).

### Chart contract on the image

Your hook Jobs call five scripts that must exist inside `glpi-php-fpm`:

| Script | Called by | Runs as |
|---|---|---|
| `glpi-verify-dir.sh` | `job-verify-dir` (weight 5) | root (chowns fresh volumes) |
| `glpi-db-install.sh` | `job-db-init` (weight 10) | 82 |
| `glpi-db-upgrade.sh` | `job-db-init` (weight 10) | 82 |
| `glpi-db-configure.sh` | `job-glpi-configure` (weight 20) | 82 |
| `glpi-cache-configure.sh` | `job-glpi-cache` (weight 30) | 82 |

The `Dockerfile` has the `COPY docker/glpi-*.sh` line ready but commented out, and
`smoke.sh` reports which ones are missing. Add them to `docker/` and uncomment.

### One chart change is required

`templates/nginx-configmap.yaml` uses `listen 80;` and `deployment.yaml` declares
`containerPort: 80`, while the pod runs with `runAsUser: 82` and
`capabilities: drop: [ALL]`. Binding a privileged port needs `NET_BIND_SERVICE`, which
is dropped — so either:

* **preferred:** `listen 8080;` + `containerPort: 8080` (the Service keeps `port: 80`
  and targets the named port `http`, so nothing outside the pod changes), or
* add `NET_BIND_SERVICE` back to `securityContext.capabilities.add`.

Verify what your node currently allows:

```bash
sysctl net.ipv4.ip_unprivileged_port_start   # 1024 = port 80 needs the capability
```

## 5. First run

```bash
./ci/pin-version.sh 12.0.2      # once per GLPI upgrade — commit the result
```

Then hit *Build with Parameters*. A green run means:

1. both images built with a verified upstream archive,
2. a cold install succeeded on MariaDB 11.8,
3. login page, `api.php` → 403 (auth required), `database:is_up_to_date`, uid 82,
4. no PHP errors logged,
5. no HIGH/CRITICAL fixable CVEs,
6. GitOps repo bumped and ArgoCD healthy, edge answering.

## 6. Running locally

Same scripts, no Jenkins:

```bash
export TAG=12.0.2-local
./ci/build.sh && ./ci/smoke.sh
```

Requires Docker only. `ci/config.sh` supplies defaults for everything Jenkins injects.

**Windows:** run the scripts from **Git Bash** (`C:\Program Files\Git\bin\bash.exe`),
not from `cmd`/PowerShell directly, and keep Docker Desktop running. `RUN.md` has the
copy-paste version.

## 7. Deliberate omissions (next iterations)

* **Upgrade-path test** — the smoke test only covers a cold install. The risk that
  matters for 11 → 12 is the migration itself: add a fixture dump of your current
  database, restore it into the throwaway stack, run `database:update` and assert
  `database:is_up_to_date`. That is the test that would have caught a failed
  pre-sync Job before it hit prod.
* **Build cache** — currently `--cache-from` on the version tag. Next: BuildKit
  registry cache (`--cache-to type=registry`), which cuts the composer/npm layer from
  every build.
* **Lean runtime** — build toolchain and `-dev` libs are still in `glpi-php`; a
  compile stage copying `.so` files removes ~300 MB and a lot of Trivy noise.
* **SBOM + provenance** — `trivy --format cyclonedx` and `--attest` in `build.sh`.
* **PR previews** — one ArgoCD ApplicationSet + namespace per PR, reusing the same
  images by tag, so reviewers can click the change instead of reading a diff.
