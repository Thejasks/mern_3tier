# Argo CD — Architecture, Components & Production Notes (teaching / interview guide)

A from-scratch guide to Argo CD: what it is, how it's built, the concepts that come
up in real work and interviews, and how it all maps to **this** MERN GitOps repo.

---

## 1. What problem does it solve? (GitOps in one paragraph)

**GitOps** = the desired state of your cluster lives in **Git**, and a controller
**continuously reconciles** the cluster to match Git. Git becomes the single source
of truth and the audit log; deploys are `git push` + a merge; rollback is `git revert`.

Two styles of delivery:

```
   PUSH (classic CI/CD)                 PULL (GitOps / Argo CD)
   CI ── kubectl apply ──▶ cluster      Git ◀── watches ── Argo CD ──▶ cluster
   - CI needs cluster creds             - cluster pulls its own state
   - drift is invisible                 - drift is detected & (optionally) healed
   - no single source of truth          - Git IS the source of truth
```

Argo CD is the **CD half** (the puller). Your CI (Jenkins here) only builds/pushes
images and writes the new image tag to Git — it never touches the cluster.

---

## 2. Architecture & components

```
                ┌────────────────────────── Argo CD (namespace: argocd) ──────────────────────────┐
                │                                                                                   │
   Git repo ───▶│  repo-server ──renders manifests (helm template / kustomize / plain yaml)─┐       │
  (this repo)   │      ▲  clones repos, caches, runs the templating tools                    │       │
                │      │                                                                      ▼       │
   kubectl /    │  API server (argocd-server) ──── application-controller ───────────────▶ live K8s │
   UI / CLI ───▶│   - gRPC/REST + Web UI            - the reconcile engine                  API      │
   SSO (dex)    │   - authN/authZ (RBAC)            - diff desired vs live                  (your    │
                │   - serves app state              - sync, prune, self-heal, health        cluster) │
                │      │                             - emits events/metrics                          │
                │  redis (cache)        applicationset-controller (generates Applications)           │
                │                       notifications-controller (Slack/email/webhooks)              │
                └───────────────────────────────────────────────────────────────────────────────────┘
```

| Component | Role | Interview-worthy detail |
|---|---|---|
| **argocd-server** (API) | REST/gRPC API + Web UI; auth, RBAC, exposes app state | Stateless; scale horizontally; the thing you port-forward/ingress |
| **repo-server** | Clones Git, runs `helm template`/`kustomize build`, returns plain manifests | CPU/mem heavy on big repos; cache here; **manifests are rendered here, not in the cluster** |
| **application-controller** | The reconcile loop: compare desired (from repo-server) vs live, sync, report health | The "brain"; sharded by cluster for scale; StatefulSet |
| **redis** | Ephemeral cache for repo-server/controller | Not a datastore — losing it just rebuilds cache |
| **dex** (optional) | SSO/OIDC federation (Google, GitHub, LDAP…) | Skip if using built-in admin or external OIDC directly |
| **applicationset-controller** | Templates many Applications from generators | For fleets: per-cluster, per-env, per-PR apps |
| **notifications-controller** | Sends sync/health events outbound | Slack/Teams/email on degraded/sync |

> **Where is state stored?** Argo CD is (mostly) **stateless** — its source of truth is
> Git + live cluster. `Application`/`AppProject` objects are stored as **CRDs in etcd**.
> Redis is just a cache. This is why "reinstall Argo CD" is low-risk.

---

## 3. Core objects

### 3.1 `Application` — the unit of deployment
Maps **a source (Git path/chart)** → **a destination (cluster + namespace)**.

```yaml
kind: Application
spec:
  project: mern                      # which AppProject governs it
  source:                            # WHERE the manifests come from
    repoURL: ...; path: charts/backend; targetRevision: main
    helm: { valueFiles: [...] }
  destination:                       # WHERE they go
    server: https://kubernetes.default.svc
    namespace: mern-dev
  syncPolicy: { automated: { prune: true, selfHeal: true } }
```

### 3.2 `AppProject` — guardrails / multi-tenancy
A boundary around a group of Applications: which **repos**, which **destinations**
(cluster+namespace), and which **resource kinds** are allowed. Default project = wide
open; real orgs create projects per team/tenant.

```yaml
kind: AppProject            # this repo: argocd/project.yaml ("mern")
spec:
  sourceRepos: [ <only this repo> ]
  destinations: [ mern-dev, mern-prod, argocd ]
  clusterResourceWhitelist: [...]   # may it create cluster-scoped objects?
```

### 3.3 `ApplicationSet` — generate Applications at scale
A factory. Generators (list, cluster, git-directory, PR, matrix) stamp out many
Applications from one template (e.g. one app per environment folder, or per cluster).

---

## 4. The reconcile loop (how a sync actually works)

```
   1. repo-server renders desired manifests from Git (helm template …)
   2. controller fetches LIVE state from the cluster
   3. DIFF  desired  vs  live   →  Sync status: Synced | OutOfSync
   4. if auto-sync (or manual Sync): apply the diff
        - prune:   delete live objects no longer in Git
        - selfHeal: revert manual kubectl changes back to Git
   5. assess HEALTH of the resulting objects → Healthy | Progressing | Degraded …
   6. repeat (default reconcile every ~3 min, or on webhook / manual refresh)
```

Two **independent** statuses people confuse:

| Status | Question it answers | Values |
|---|---|---|
| **Sync** | Does the cluster match Git? | `Synced`, `OutOfSync` |
| **Health** | Are the running objects actually OK? | `Healthy`, `Progressing`, `Degraded`, `Missing`, `Suspended` |

> You can be **Synced + Degraded** (Git applied, but the pod crash-loops) or
> **OutOfSync + Healthy** (running fine, but Git moved ahead). In this repo we hit
> exactly the first case while Mongo was starting — backend was *Synced* but
> *Progressing/Degraded* until `/healthz` passed.

### 4.1 Sync policy knobs
- **automated** — sync without a human (vs manual "Sync" click).
- **selfHeal: true** — revert out-of-band `kubectl` edits (Git wins). *(This is why
  manually scaling a Deployment gets reverted — you saw this.)*
- **prune: true** — delete resources removed from Git (careful in prod).
- **syncOptions** — e.g. `CreateNamespace=true`, `ServerSideApply=true`,
  `ApplyOutOfSyncOnly=true`.

### 4.2 Sync waves & hooks (ordering)
Annotation `argocd.argoproj.io/sync-wave: "N"` orders resources (low → high).
This repo uses waves **mongodb(0) → backend(1) → frontend(2)** so the DB is up first.
**Resource hooks** (`PreSync`/`Sync`/`PostSync`) run Jobs at sync time — DB migrations,
smoke tests, etc.

---

## 5. App-of-Apps & multi-source (the patterns this repo uses)

### App-of-Apps
One **root** Application whose source is a *folder of Application manifests*. Apply the
root once → it pulls in all the children. Bootstrap the whole platform with a single
`kubectl apply`.

```
   root (mern-dev)  ──renders──▶ argocd/apps/dev/*.yaml
        │
        ├─▶ Application mongodb-dev   (wave 0)
        ├─▶ Application backend-dev   (wave 1)
        └─▶ Application frontend-dev  (wave 2)
```
Files: `argocd/root-dev.yaml`, `argocd/root-prod.yaml`, `argocd/apps/<env>/*.yaml`.

### Multi-source Applications
Each child app pulls from the **same repo twice**: once for the **chart** (`charts/<app>`)
and once as a **values reference** (`$values/environments/<env>/<app>.yaml`). This keeps
charts reusable and env values separate — the standard way to do Helm + per-env overlays
in Argo CD ≥ 2.6.

---

## 6. Production concerns (what interviewers probe)

- **RBAC** — `argocd-rbac-cm` maps SSO groups → roles (e.g. `role:readonly`,
  per-project admin). Restrict who can sync prod.
- **Projects per tenant** — don't dump everything in `default`; scope repos/destinations.
- **Secrets** — Argo CD does **not** solve secret management. Pair it with
  **Sealed Secrets / External Secrets Operator / SOPS / Vault**. Never commit plaintext
  (this demo commits base64 for teaching only — call that out).
- **Sync windows** — block/allow syncs by schedule (e.g. no prod sync on Fridays).
- **Drift & self-heal** — selfHeal keeps the cluster honest; some teams leave it off in
  prod and sync via PR + manual promote.
- **Prod promotion** — image tags pinned in Git; promote dev→prod by **PR**, not by CI
  auto-write (this repo: CI bumps only `environments/dev`, prod is a human PR).
- **HA** — run multiple replicas of server/repo-server; **shard** the application
  controller across many clusters; externalize redis (redis-ha).
- **Scale** — repo-server is the usual bottleneck (templating); give it CPU and enable
  caching/manifest generation paths; shard controllers by cluster.
- **Observability** — Argo CD exports Prometheus metrics (sync counts, health, repo
  latency); wire `notifications-controller` for Slack on `degraded`.
- **Disaster recovery** — back up the `Application`/`AppProject` CRDs and the
  `argocd-*-cm`/secrets; everything else re-derives from Git.

---

## 7. Common interview Q&A (rapid fire)

- **GitOps vs traditional CI/CD?** Pull vs push; Git is the source of truth; drift
  detection + reconciliation; cluster creds stay in the cluster.
- **Sync vs Health?** Sync = matches Git?; Health = objects actually OK? Independent.
- **What does self-heal do?** Reverts out-of-band changes back to Git state.
- **App-of-Apps?** A root Application that manages child Applications → one-command
  bootstrap.
- **ApplicationSet vs App-of-Apps?** ApplicationSet *generates* apps from generators
  (per-cluster/env/PR); App-of-Apps is a static list of children. Use ApplicationSet
  for fleets.
- **Where are manifests rendered?** In **repo-server** (helm template/kustomize build),
  then the controller applies plain manifests — Tiller-free, no Helm release in-cluster.
- **How does Argo CD authenticate to private Git?** A `repository` Secret
  (labeled `argocd.argoproj.io/secret-type: repository`) with token/SSH key. *(This repo
  added one for the private `mern_cicd`.)*
- **How to order resources?** sync-waves + hooks.
- **How does rollback work?** `git revert` (or Argo CD "History → Rollback" to a prior
  synced revision).
- **Is Argo CD stateful?** Largely no — Git + live cluster are truth; CRDs in etcd;
  redis is cache.
- **Multi-cluster?** Register external clusters as secrets; one Argo CD manages many;
  controller shards per cluster.

---

## 8. How this repo is wired (cheat sheet)

```
   Jenkins (app repos) ──build/scan──▶ ECR ──┐
        └── git commit new tag ─────────────┐ │
                                            ▼ │
   mern_cicd (Git)  ◀──────── Argo CD watches │
     argocd/project.yaml          (App-of-Apps)
     argocd/root-dev.yaml ──▶ apps/dev/{mongodb,backend,frontend}.yaml
        each app:  charts/<app>  +  environments/dev/<app>.yaml  (multi-source)
                                            │ sync waves 0→1→2
                                            ▼
                                   namespace mern-dev  (Pods on EBS, ECR images)
```

Bootstrap it all:
```bash
./install/argocd-setup.sh dev     # install Argo CD + repo cred + ECR secret + App-of-Apps
kubectl -n argocd port-forward svc/argocd-server 8080:443   # UI at https://localhost:8080
kubectl get applications -n argocd                          # watch sync/health
```

See also: [`ECR-and-ALB.md`](./ECR-and-ALB.md) for registry + load-balancer flows.
