# RUN — see the pipeline go

Three levels. Start at **A**; each one adds a layer.

| Level | Needs | Time | Proves |
|---|---|---|---|
| A. Local build + smoke | Docker Desktop + Git Bash | 10–25 min first time | the image really installs GLPI and serves it |
| B. Jenkins | Docker Desktop | +5 min | the same scripts run from a controller, stages gated |
| C. ArgoCD on k3s | a cluster | — | deploy + rollback via git |

---

## A. Local build + smoke (no Jenkins)

Open **Git Bash** (not PowerShell — the scripts are bash) and:

```bash
cd "/c/Users/idk/Desktop/CICD pipline"
export MSYS_NO_PATHCONV=1          # stops Git Bash rewriting container paths
./ci/prepare.sh                    # toolchain + upstream tag + cache warm
./ci/build.sh                      # builds glpi-php-fpm + glpi-nginx
./ci/smoke.sh                      # cold install + boot + assertions
```

What a green run looks like:

```
==> php-fpm image
  ok: docker.io/mdbak/glpi-php-fpm:12.0.2-local
==> nginx image
  ok: docker.io/mdbak/glpi-nginx:12.0.2-local
...
==> start database
  ok: mariadb healthy
==> install schema (cold install, not an upgrade)
  ok: database:install succeeded
==> checks
  ok: login page rendered (… bytes)
  ok: api.php -> 403 (auth required)
  ok: database:is_up_to_date
  ok: runs as uid 82
  ok: index.php served
  ok: no PHP errors logged
    WARNING: missing chart hook script(s):        ← expected, see ROADMAP step 4
==> smoke test passed
```

Logs land in `.ci-out/` (gitignored). If it fails, `.ci-out/compose.log` has the
container output.

Optional extra gates:

```bash
./ci/scan.sh        # Trivy HIGH/CRITICAL gate (pulls aquasec/trivy)
./ci/cleanup.sh     # stop the smoke stack and remove its temporary GitOps clone
```

### Watch the app while the smoke test runs

`ci/smoke.sh` tears the stack down on exit, so run the stack by hand if you want
to click around:

```bash
export TAG=12.0.2-local MSYS_NO_PATHCONV=1
C="docker compose -p glpi-demo -f ci/docker-compose.test.yml -f ci/docker-compose.demo.yml"
$C up -d --wait db
$C run --rm install
$C up -d --no-deps php web
# then: http://localhost:8090  (login: glpi/glpi)
```

`ci/docker-compose.demo.yml` publishes nginx on **8090** — 8080 is commonly
already in use. Stop it with `$C down -v`.

---

## B. Jenkins

Use the existing Jenkins controller at <http://192.168.1.50:8080>. Its Linux build
agent needs Bash, Git, Docker CLI + daemon access, Docker Compose, `yq`, and the
Jenkins plugins Git, Pipeline, Pipeline: Multibranch, Credentials Binding, and
Timestamper.

Create the multibranch job and trigger its first branch scan from Git Bash at the
repository root:

```bash
export JENKINS_URL=http://192.168.1.50:8080
export JENKINS_ADMIN_USER=admin
read -rsp "Jenkins password or API token: " JENKINS_ADMIN_PASSWORD; echo
export JENKINS_ADMIN_PASSWORD
./jenkins/setup-job.sh
```

The job definition lives in `jenkins/multibranch.xml`; it scans for branch changes
every five minutes. The setup script uses your existing Jenkins login and triggers
the initial scan.

Then add these credentials in Jenkins for the `main` delivery stages:

`registry-creds` (Docker Hub push access) and `gitops-token` (write access to the
GitOps repo) — see `README-CICD.md` §2. Jenkins publishes both images and commits
their new digest tags to `values-prod.yaml`; ArgoCD watches that repo and performs
the rollout. Jenkins does not need an ArgoCD token. To exercise the build, smoke,
and scan path without delivery credentials, use the `demo` branch.

A PR (or any non-`main` branch) stops after Scan. A `main` build continues to
Publish → update GitOps values. Both delivery credentials must exist or the `main` build
will fail at the first stage that needs the missing credential.

---

## C. ArgoCD (cluster)

```bash
kubectl create namespace glpi
kubectl -n glpi create secret generic my-test-app-auth \
  --from-literal=mariadb-user-password='…' \
  --from-literal=mariadb-root-password='…' \
  --from-literal=mariadb-replication-password='…' \
  --from-literal=valkey-password='…'

kubectl apply -f https://raw.githubusercontent.com/MohamedBakrim/glpi-gitops-cicd/main/argocd/application.yaml
argocd app get glpi --refresh
```

ArgoCD renders `glpi-chart-cicd` with `values-prod.yaml` from
`glpi-gitops-cicd`. A pipeline bump is a commit in the GitOps repo; rollback is
`git revert` of that commit.

---

## Repos and remotes

```
C:\Users\idk\Desktop\CICD pipline        → glpi-app-cicd      (this repo)
C:\Users\idk\Desktop\glpi-chart-cicd     → glpi-chart-cicd
C:\Users\idk\Desktop\glpi-gitops-cicd    → glpi-gitops-cicd
```

If you edit and want to publish:

```bash
cd "/c/Users/idk/Desktop/glpi-chart-cicd" && git add -A && git commit -m "…" && git push
```
