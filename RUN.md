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
./ci/cleanup.sh     # drop the smoke stack + secrets + dangling images
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

```bash
cd jenkins
echo "DOCKER_GID=$(getent group docker | cut -d: -f3)" > .env   # Linux; skip on Docker Desktop
docker compose up -d --build
```

Open <http://localhost:8080>, unlock with the initial admin password printed by
`docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword`, install
the suggested plugins plus **GitHub Branch Source** and **Credentials Binding**.

Then:

1. **New Item → Multibranch Pipeline → Git**
   `https://github.com/MohamedBakrim/glpi-app-cicd.git`
2. Build configuration: **by Jenkinsfile**
3. Credentials (only needed for Publish/GitOps/Verify):
   `registry-creds`, `gitops-token`, `argocd-token` — see `README-CICD.md` §2.
4. **Build with Parameters** → `GLPI_VERSION=12.0.2`.

A PR build stops after Scan. A `main` build continues to Publish → GitOps bump →
Verify. If you have not set `registry-creds`, comment out those three stages in
the `Jenkinsfile` for the first run.

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
