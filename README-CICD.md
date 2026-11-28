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
ci/cleanup.sh              stop smoke stack, remove temporary GitOps clone
ci/pin-version.sh          pin an upstream archive checksum
ci/glpi.sha256             pinned versions
docker/                    (TODO) the five glpi-*.sh hook scripts the chart calls
jenkins/                   multibranch job definition + REST setup script
```

## 1. Use the existing Jenkins controller

Jenkins is already deployed at <http://192.168.1.50:8080>. The pipeline needs a
Linux agent with **Bash**, **Git**, **Docker CLI + daemon access**, **Docker Compose**,
and **yq**. The Jenkins instance needs **Git**, **Pipeline**, **Pipeline: Multibranch**,
**Credentials Binding**, and **Timestamper**. It does not need cluster or ArgoCD access.

If builds run on the controller, it needs Docker socket access. That grants the
builds root-equivalent control of the Docker host; allow only trusted branches to
run pipeline changes with that access.

## 2. Credentials

| ID | Kind | Used by | Notes |
|---|---|---|---|
| `registry-creds` | username/password | `publish.sh` | Docker Hub account or access token with push rights to `mdbak/glpi-php-fpm` and `mdbak/glpi-nginx` |
| `gitops-token` | secret text | `bump.sh` | PAT with `contents:write` on the GitOps repo |

## 3. Job

Create the multibranch job from Git Bash:

```bash
# Defaults to your existing Jenkins URL. Use your account name and password/API token.
export JENKINS_ADMIN_USER=admin
read -rsp "Jenkins password or API token: " JENKINS_ADMIN_PASSWORD; echo
export JENKINS_ADMIN_PASSWORD
./jenkins/setup-job.sh
```

`jenkins/multibranch.xml` is the source of truth: it points at this repository,
loads `Jenkinsfile`, and scans branches every five minutes. The script triggers an
initial scan. Rerunning it leaves an existing job in place and triggers another scan.

Behaviour:

| Build | Build + smoke + scan | Publish | GitOps values commit |
|---|---|---|---|
| pull request / `demo` | ✅ | ❌ | ❌ |
| `main` | ✅ | ✅ | ✅ |

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

The pipeline builds and pushes both images to Docker Hub. `publish.sh` records each
manifest digest in `.ci-out/digests.env`; `bump.sh` updates the two image tags in
`values-prod.yaml` to `<version>@sha256:<digest>` and pushes a commit to the GitOps
repo. The image repository names stay fixed. ArgoCD watches that GitOps repo and
performs the sync and rollout; Jenkins does not call ArgoCD or the cluster.
A moved or re-pushed tag therefore cannot change what runs — only a new Git commit can.

`GITOPS_VALUES_FILE` points at the values file ArgoCD actually reads. In the
`glpi-gitops-cicd` repo that is `values-prod.yaml` at the repo root, and
`argocd/application.yaml` wires it into the chart as a second source (`$values`).

ArgoCD application must run with automated sync + `selfHeal: true`. Once the GitOps
commit lands, ArgoCD applies the new digest-pinned images and handles the rollout. The
chart owns the migration chain (`verify-dir` → `db-install`/`db-upgrade` → `configure` → `cache`).

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
6. GitOps repo updated with the new image digests. ArgoCD then handles sync and rollout.

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
