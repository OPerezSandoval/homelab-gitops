# Homelab GitOps

GitOps repository managing a single Talos Kubernetes cluster. ArgoCD pulls from `main` and continuously reconciles platform infrastructure and applications.

## Architecture

```
                          Cluster (Talos, single node)
                                       │
                 ┌─────────────────────┼─────────────────────┐
                 │                     │                     │
          Application/apps      Application/infra     Application/argocd
              (parent)              (parent)         (self-managing; also
                 │                     │              manages ArgoCD install)
                 │ renders             │ renders
                 ▼                     ▼
      kubernetes/apps/base/      kubernetes/infra/
                 │                     │
                 ▼                     ▼
      2 ApplicationSets         8 platform Apps
      + 3 manual Apps
                 │
                 │ auto-generate
                 ▼
                Apps
```

Three top-level Applications:

- **`apps`** owns user apps. Two ApplicationSets scan `overlays/{dev,prod}/*` and auto-generate Applications for every overlay folder. One exception (n8n) keeps a manual `app.yaml` because it doesn't fit the pure kustomize-overlay pattern.
- **`infra`** owns platform components - ingress, secrets, networking, metrics.
- **`argocd`** is self-managing and also manages the ArgoCD install itself via a remote kustomize base pinned to a specific upstream version. Upgrading ArgoCD = bump the version in one line.

There is **one** physical cluster. Dev/prod separation happens at the namespace level via Kustomize overlays, not at the cluster level.

## Directory layout

```
clusters/
  talos-dev/
    apps.yaml             ← Bootstrap manifest: declares the apps + infra Applications
    kustomization.yaml

kubernetes/
  argocd-bootstrap/       ← One-time install + ongoing source for the argocd Application
    kustomization.yaml    ← References upstream ArgoCD install (pinned version) + binding
    cluster-admin-binding.yaml

  infra/                  ← Platform layer, owned by Application/infra
    kustomization.yaml    ← Lists each infra Application folder
    argocd/               ← Self-managing Application (points at ../argocd-bootstrap)
    cloudflare/           ← Cloudflared tunnel (Git source)
    external-secrets-operator/
      extras/             ← ClusterSecretStore (multi-source Git extras)
    headlamp/
    metallb/
    metallb-config/
      base/               ← IPAddressPool + L2Advertisement (Git source path)
    metrics-server/
    tailscale/
      extras/             ← ExternalSecret for tailscale operator OAuth
    vault/
      extras/             ← Vault UI Ingress
    cert-manager/         
    monitoring/           

  apps/                   
   Application/apps
    base/
      kustomization.yaml  ← Lists applicationsets, n8n
      applicationsets/    ← Two ApplicationSets that auto-generate workload Applications
      archeflow-site/
        base/             ← Raw manifests (referenced by overlays)
      kustomize-demo/
        base/
      medtracker/
        base/
      n8n/                ← Exception: single-instance Helm chart
        extras/           ← n8n ExternalSecret
      kafka/  strimzi/    ← Orphan demo folders, not in kustomization
    overlays/
      dev/<app>/          ← Per-env Kustomize overlays (namespace, image tag, replicas, ingress)
      prod/<app>/         ← Same structure
```

## Tooling

- **ArgoCD v3.5+** — pulls from `main`, runs in the `argo-gitops` namespace. The ArgoCD install itself is GitOps-managed via a remote kustomize base.
- **ApplicationSet** — auto-discovers workloads. Add an overlay folder, get an Application for free.
- **Kustomize** — directory composition for umbrellas and overlays.
- **Helm** — used via ArgoCD Helm source for third-party charts (Vault, ESO, Tailscale, etc.). Three apps use multi-source (vault, external-secrets, tailscale-operator, n8n) — chart + Git extras.
- **Vault + External Secrets Operator** — Vault is the secret source of truth; ESO renders `ExternalSecret` resources into Kubernetes `Secret`s.
- **Talos Linux** — cluster OS. CNI is **Cilium**, managed at the Talos layer (not via this repo).
- **Tailscale operator** — primary ingress (`ingressClassName: tailscale`), backed by MagicDNS hostnames on the tailnet.
- **Cloudflared tunnel** — public exposure for public hostnames.

## Bootstrapping a fresh cluster

```bash
# 1. Install ArgoCD + cluster-admin binding (rendered from upstream + local patch)
kubectl apply -k kubernetes/argocd-bootstrap

# 2. Wait for ArgoCD pods to come up
kubectl -n argo-gitops wait --for=condition=Available deployment --all

# 3. Register the umbrella Applications (apps + infra)
kubectl apply -f clusters/talos-dev/apps.yaml

# 4. ArgoCD discovers and syncs everything from main
kubectl -n argo-gitops get app -w
```

Vault comes up sealed on first boot 

## Adding a new app

### User applications (kustomize-overlay pattern)

For most applications (deployment + service + per-env overlay). **No `app.yaml` needed** — ApplicationSet auto-generates it from the overlay folder.

```
kubernetes/apps/base/<app>/
  base/
    deployment.yaml
    service.yaml
    kustomization.yaml

kubernetes/apps/overlays/dev/<app>/
  kustomization.yaml      ← References ../../../base/<app>/base, sets namespace, image tag, replicas
  ingress.yaml            ← Optional tailscale Ingress

kubernetes/apps/overlays/prod/<app>/
  kustomization.yaml      ← Same shape, prod values
  ingress.yaml
```

Open PR, merge. `ApplicationSet/workloads-dev` and `workloads-prod` pick up the new overlay folders and generate `Application/<app>-dev` and `<app>-prod` automatically.

To remove: delete the overlay folders, merge. ApplicationSet auto-deletes the Applications.

### Third-party Helm chart (infrastructure)

```bash
mkdir -p kubernetes/infra/<chart>
```

1. Create `kubernetes/infra/<chart>/app.yaml` — ArgoCD `Application` with a Helm source.
2. Create `kubernetes/infra/<chart>/kustomization.yaml`:
   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - app.yaml
   ```
3. Add `<chart>` to `kubernetes/infra/kustomization.yaml` under `resources:`.
4. If the chart needs extra Git-rendered resources (Ingress, ExternalSecret, ConfigMap, etc.), use a multi-source Application — see `kubernetes/infra/vault/app.yaml` as the canonical example. Drop the raw manifests under `kubernetes/infra/<chart>/extras/` with their own `kustomization.yaml`.
5. Open PR. After merge, the `infra` umbrella creates the new Application automatically.

## Upgrading ArgoCD

One-line PR:

```diff
# kubernetes/argocd-bootstrap/kustomization.yaml
- - https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.1/manifests/install.yaml
+ - https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.2/manifests/install.yaml
```

Open PR, merge. `Application/argocd` auto-syncs and rolls the new version in. ArgoCD upgrades itself.

Live `argocd-cm` / `argocd-rbac-cm` / `argocd-cmd-params-cm` / `argocd-secret` data is preserved across upgrades via `ignoreDifferences` on the Application — that custom config isn't yet captured in Git.

## Secrets

ESO syncs Vault → Kubernetes Secrets.

```
Vault (in-cluster)
   │
   └─► external-secrets-operator
              │
              ├─► ClusterSecretStore/vault-backend (cluster-wide bridge)
              │
              └─► ExternalSecret/<name> (per workload)
                       │
                       └─► Secret/<name> (namespace-scoped, consumed by Pod)
```

To add a new secret:

1. Write to Vault: `vault kv put secret/<app>/<key> value=...`
2. In the app folder's `extras/`, add an `ExternalSecret`:
   ```yaml
   apiVersion: external-secrets.io/v1beta1
   kind: ExternalSecret
   metadata:
     name: <app>-secret
     namespace: <app>
   spec:
     refreshInterval: 1h
     secretStoreRef:
       name: vault-backend
       kind: ClusterSecretStore
     target:
       name: <app>-secret
     data:
       - secretKey: <ENV_VAR_NAME>
         remoteRef:
           key: <app>/<key>
   ```
3. Reference the rendered `Secret` from the workload via `envFrom.secretRef` or `volumes.secret`.

## Networking

- **Tailscale operator** (`ingressClassName: tailscale`) is the primary ingress controller. Each Ingress becomes a Tailscale device with a MagicDNS hostname `<host>.balinese-pentatonic.ts.net`, reachable to anyone on the tailnet. Use this for admin UIs and internal services.
- **Cloudflared tunnel** exposes public-facing services (e.g. `archeflow.com`) via outbound tunnel — no inbound port forwarding, no public IP required.

## Disaster recovery

> **See [`docs/DR-RUNBOOK.md`](docs/DR-RUNBOOK.md) for the full runbook** —
> triage order, what *not* to do during the ESO cascade, Talos upgrade
> requirements, backup/restore procedure, and the traps that have actually
> bitten. The summary below covers the one manual step in a normal recovery.

### Vault unseal

Vault comes up sealed after any pod restart. Unseal with three of the five keys:

```bash
kubectl -n vault exec vault-0 -- vault operator unseal <KEY_1>
kubectl -n vault exec vault-0 -- vault operator unseal <KEY_2>
kubectl -n vault exec vault-0 -- vault operator unseal <KEY_3>
```

Unseal keys are stored **off-cluster** — never in this repo. Document their location in your personal password manager.

### Rebuild from scratch

1. Provision a fresh Talos cluster.
2. Run the [Bootstrapping](#bootstrapping-a-fresh-cluster) sequence.
3. After ArgoCD syncs and Vault pods are up, restore Vault from snapshot backup.
4. ESO re-renders all `Secret` resources; workloads recover.

### Rollback an application

Point the Application at a known-good tag:

```bash
kubectl -n argo-gitops patch app <name> --type=merge \
  -p '{"spec":{"source":{"targetRevision":"<commit-sha-or-tag>"}}}'
```

Or edit the umbrella's `targetRevision` in `clusters/talos-dev/apps.yaml` and re-apply.
