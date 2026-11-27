# Roadmap — GLPI 12 → k3s via ArgoCD

**Rule:** one step at a time. A step is done only when its **gate** passes and you can
say what it proved. Never start step N+1 on a red gate — every step depends on the
artifact of the one before it.

| # | Step | Gate (the command that proves it) | Host |
|---|---|---|---|
| 1 | Repo + php-fpm image | `docker build --target php-fpm` exits 0, extensions load | build host |
| 2 | nginx image | `nginx -t` says `syntax is ok`, serves `index.php` | build host |
| 3 | Smoke stack | `bash ci/smoke.sh` exits 0 | build host |
| 4 | Chart hook scripts | smoke prints `chart hook scripts present` | build host |
| 5 | Publish images | `docker manifest inspect` shows both digests | build host |
| 6 | Chart values + port | `helm template` renders your tags, uid 82, port 8080 | local |
| 7 | GitOps repo + ArgoCD | `argocd app get glpi` → `Synced` / `Healthy` | cluster |
| 8 | Migration path | pre-sync Job upgrades an 11.x dump to 12 | cluster |
| 9 | Jenkins end-to-end | one green `main` build moves the cluster | Jenkins |
| 10 | Rollback drill | `git revert` puts the old pods back | cluster |

## Why this order

```
image ──► smoke-proven image ──► registry ──► chart values ──► ArgoCD ──► Jenkins
```

* Steps 1–4 are **artifact** work: there is nothing to deploy until the image runs.
* Step 5 is the **handoff**: after this the cluster can pull it.
* Steps 6–8 are **cluster** work: chart, GitOps, migration. Still manual sync.
* Step 9 automates the loop only after it works by hand. A pipeline that hides a
  broken chart just makes the breakage scheduled.
* Step 10 is the actual proof the design works: deploy is reversible.

## Open blockers carried from the design phase

1. **Five hook scripts** the chart calls from `/usr/local/bin` are not in the image
   yet (`glpi-verify-dir.sh`, `glpi-db-install.sh`, `glpi-db-upgrade.sh`,
   `glpi-db-configure.sh`, `glpi-cache-configure.sh`). Addressed in step 4.
2. **Port 80 vs 8080** — chart runs nginx as UID 82 with `capabilities.drop: [ALL]`.
   Addressed in step 6.
3. **Where ArgoCD reads values** — the chart repo has no `values-prod.yaml`.
   Addressed in step 7.

## Progress

- [ ] 1 · repo + php-fpm image
- [ ] 2 · nginx image
- [ ] 3 · smoke stack
- [ ] 4 · hook scripts
- [ ] 5 · publish
- [ ] 6 · chart values + port
- [ ] 7 · GitOps + ArgoCD
- [ ] 8 · migration path
- [ ] 9 · Jenkins end-to-end
- [ ] 10 · rollback drill
