# Homelab GitOps

GitOps repository managing a single Talos Kubernetes cluster. ArgoCD pulls from `main` and continuously reconciles platform infrastructure and applications.

## Architecture

```
                       Cluster (Talos, single node)
                                    │
              ┌─────────────────────┼─────────────────────┐
              │                     │                     │
       Application/apps      Application/infra     Application/argocd
           (parent)              (parent)            (self-managing)
              │                     │
              │ renders             │ renders
              ▼                     ▼
   kubernetes/apps/base/    kubernetes/infra/
              │                     │
              ▼                     ▼
   9 workload Apps          8 platform Apps
```

Two umbrella Applications split responsibility:

- **`apps`** owns user workloads. Each workload typically has `-dev` and `-prod` Applications pointing at per-env overlays.
- **`infra`** owns platform components — ingress, secrets, networking, observability.

There is **one** physical cluster. Dev/prod separation happens at the namespace level via Kustomize overlays, not at the cluster level.

## Directory layout

```
clusters/
  talos-dev/
    apps.yaml             ← Bootstrap manifest: declares the apps + infra
    kustomization.yaml

kubernetes/
  argocd-bootstrap/       ← One-time install: ArgoCD + cluster-admin ClusterRoleBinding
    install.yaml
    cluster-admin-binding.yaml
    kustomization.yaml

  infra/                  ← Platform layer, owned by Application/infra
    kustomization.yaml    ← Lists each infra Application folder
    argocd/               
    cloudflare/           ← Cloudflared tunnel (Git source)
    external-secrets-operator/
    headlamp/
    metallb/              
    metallb-config/       
    metrics-server/
    tailscale/            ← Primary ingress controller
    vault/
    cert-manager/         
    monitoring/           

  apps/                   ← User workloads, owned by Application/apps
    base/
      kustomization.yaml  ← Lists each workload Application folder
      archeflow-site/     ← Per-app: app.yaml (Applications) + base/ (manifests)
      helm-demo/          
      kustomize-demo/     
      n8n/
      kafka/  strimzi/    
    overlays/.            ← Per-env Kustomize overlays (namespace, image tag, replicas, ingress)
      dev/<app>/          
      prod/<app>/         
```

## Tooling

- **ArgoCD v3.2+** — pulls from `main`, runs in the `argo-gitops` namespace.
- **Kustomize** — directory composition for umbrellas and overlays.
- **Helm** — used via ArgoCD Helm source for third-party charts (Vault, ESO, Tailscale, etc.).
- **Vault + External Secrets Operator** — Vault is the secret source of truth; ESO renders `ExternalSecret` resources into Kubernetes `Secret`s.
- **Talos Linux** — cluster OS. CNI is **Cilium**, managed at the Talos layer (not via this repo).
- **Tailscale operator** — primary ingress (`ingressClassName: tailscale`), backed by MagicDNS hostnames on the tailnet.
- **Cloudflared tunnel** — public exposure for public urls .

## Bootstrapping a fresh cluster

```bash
# 1. Install ArgoCD + ClusterRoleBinding
kubectl apply -k kubernetes/argocd-bootstrap

# 2. Wait for ArgoCD pods to come up
kubectl -n argo-gitops wait --for=condition=Available deployment --all 

# 3. Register the umbrella Applications (apps + infra)
kubectl apply -f clusters/talos-dev/apps.yaml

# 4. ArgoCD discovers and syncs everything from main
kubectl -n argo-gitops get app -w
```

Vault comes up sealed on first boot — see [Disaster recovery](#disaster-recovery).

## Adding a new app

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
4. Open PR. After merge, the `infra` app creates the new Application automatically.

### User workload (with dev/prod environments)

Mirror the `medtracker` or `archeflow-site` pattern:

```
kubernetes/apps/base/<app>/
  app.yaml              ← Two Applications (-dev and -prod) pointing at overlays
  kustomization.yaml    ← resources: [app.yaml]
  base/
    deployment.yaml
    service.yaml
    kustomization.yaml

kubernetes/apps/overlays/dev/<app>/
  kustomization.yaml    ← References ../../../base/<app>/base, sets namespace, image tag, replicas
  ingress.yaml          ← Optional tailscale Ingress

kubernetes/apps/overlays/prod/<app>/
  kustomization.yaml    ← Same shape, prod values
  ingress.yaml
```

Then add `<app>` to `kubernetes/apps/base/kustomization.yaml` under `resources:`. After merge, the `apps` umbrella registers both Applications.

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
2. In the app folder, add an `ExternalSecret`:
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