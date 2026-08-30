# GitOps Infrastructure Repository

This repository contains the GitOps configuration for managing your Kubernetes infrastructure using ArgoCD.

> 🤖 **Auto-Generated**: This repository structure is managed by Skyhook. Manual edits to this file are preserved.

## 📁 Repository Structure

```
kubernetes/
├── README.md                          # This file
├── cluster-config/                    # Cluster configurations
│   └── <cluster-name>/
│       ├── config.yaml               # Cluster metadata
│       ├── appproject.yaml           # ArgoCD AppProject
│       └── values-*.yaml             # Helm values per component
├── bootstrap/                         # ArgoCD bootstrap files
│   ├── README.md                     # Detailed deployment instructions
│   ├── auto-provision-clusters/      # Centralized management setup
│   │   └── cluster-appprojects-appset.yaml
│   ├── individual-clusters/          # Distributed management setup
│   │   └── <cluster-name>-appset.yaml
│   └── cluster-components/           # Component ApplicationSets
│       ├── addons-app.yaml           # System addons
│       └── workloads-app.yaml        # Application workloads
├── addons/                           # Infrastructure add-ons (Helm/Kustomize)
│   └── <add-on-name>/
│       └── <component-name>/
│           ├── base/                 # Base configuration
│           └── overlays/             # Cluster-specific overrides
├── workloads/                        # Application workloads (per cluster)
│   └── <workload-name>/
│       └── <cluster-name>-appset.yaml
```

---

## 🚀 Quick Start

### Prerequisites

- **kubectl**: Kubernetes CLI tool
- **ArgoCD**: Installed in your cluster(s)
- **Git access**: Repository accessible from your cluster(s)
- **Admin access**: To your Kubernetes cluster(s)

### Deployment Options

#### Full Cluster Bootstrap

For complete cluster infrastructure management, choose between **two deployment architectures**:

1. **Centralized Management** (Single ArgoCD)
   - One ArgoCD instance manages all clusters
   - Centralized visibility and control
   - Deploy from: `bootstrap/auto-provision-clusters/`

2. **Distributed Management** (Multiple ArgoCD)
   - Each cluster has its own ArgoCD instance
   - Complete cluster isolation
   - Deploy from: `bootstrap/individual-clusters/`

📖 **[See detailed cluster bootstrap instructions](./bootstrap/README.md)**

#### Selective Component Deployment

You can also deploy **individual addons or workloads** without the full bootstrap:

- **Addons only**: Deploy system components (monitoring, secrets, ingress) from `addons/`
- **Workloads only**: Deploy applications from `workloads/`
- **Mix and match**: Use Skyhook for some components while managing others manually

**Example scenarios**:
- Manage addons manually, use Skyhook only for application workloads
- Use Skyhook for security addons, manage other infrastructure yourself
- Gradually migrate from manual to GitOps by starting with specific components

See [Selective Deployment](#selective-deployment) section below for details.

---

## 📂 Directory Explanations

### `cluster-config/`

Contains configuration for each Kubernetes cluster in your infrastructure.

**Per-cluster structure:**
- `config.yaml` - Cluster metadata (name, cloud provider, location, endpoint)
- `appproject.yaml` - ArgoCD AppProject defining permissions and resources
- `values-<component>.yaml` - Helm values files for each component deployed to this cluster

**Example: cluster-config/prod-us-central1/config.yaml**

**Minimal configuration:**
```yaml
cluster:
  name: prod-us-central1
  project: my-prod-project
  location: us-central1
  cloudProvider: gcp
```

**Complete configuration with all options:**
```yaml
enabled: true
cluster:
  name: prod-us-central1
  project: my-prod-project
  location: us-central1
  cloudProvider: gcp
  address: https://prod.example.com
  account: "123456789"
workloads:
  argocdProject: prod-us-central1-workloads
  targetRevision: HEAD
addons:
  argocdProject: prod-us-central1-addons
  overlay: prod-us-central1
  targetRevision: HEAD
```

**Notes:**
- If `enabled` is not specified, defaults to `true`
- If `workloads` is not specified, defaults are applied: `{argocdProject: '{cluster-name}-workloads', targetRevision: 'HEAD'}`
- If `addons` is not specified, defaults are applied: `{argocdProject: '{cluster-name}-addons', overlay: '{cluster-name}', targetRevision: 'HEAD'}`
- `cloudProvider` must be one of: `gcp`, `aws`, `azure`, `other`

### `bootstrap/`

Contains ArgoCD ApplicationSets and Applications for bootstrapping your infrastructure.

- **auto-provision-clusters/**: Single ApplicationSet that auto-discovers all clusters
- **individual-clusters/**: Per-cluster ApplicationSets for manual provisioning
- **cluster-components/**: Component Applications (addons, workloads)

📖 **[See bootstrap/README.md for deployment instructions](./bootstrap/README.md)**

### `addons/`

Infrastructure add-ons may have multiple components all grouped together by a single add-on folder (monitoring, security, networking, gateways).

Each add-on contains one or more components using either Helm or Kustomize:

**Helm component example:**
```
addons/
└── sealed-secrets/
    └── sealed-secrets-controller/      # Helm component
        ├── base/
        │   ├── Chart.yaml              # Helm chart metadata
        │   └── values.yaml             # Base values
        └── overlays/
            ├── prod-us-central1/
            │   └── values.yaml         # Cluster-specific values
            └── dev-us-west1/
                └── values.yaml
```

**Kustomize component example:**
```
addons/
└── gateways/
    └── gateway-instances/               # Kustomize component
        ├── base/
        │   ├── kustomization.yaml      # Base kustomization
        │   ├── deny-all.yaml           # Default deny policy
        │   └── allow-dns.yaml          # Allow DNS policy
        └── overlays/
            ├── prod-us-central1/
            │   ├── kustomization.yaml  # Overlay kustomization
            │   └── gateway-instance-1.yaml  # Cluster-specific policy
            └── dev-us-west1/
                ├── kustomization.yaml
                └── gateway-instance-2.yaml      # More permissive for dev
```

**Example add-ons:**
- `sealed-secrets/` - Sealed Secrets
- `gateways/` - Gateway Instances

### `workloads/`

Application workloads deployed to your clusters.

**Structure:** `workloads/<workload-name>/<cluster-name>-appset.yaml`

---

## 🔄 GitOps Workflow

### How Changes Are Applied

1. **Make changes** to configuration files in this repository
2. **Commit and push** changes to Git
3. **ArgoCD detects** changes automatically (via Git polling or webhooks)
4. **ArgoCD syncs** resources to your Kubernetes clusters
5. **Verify** changes in ArgoCD UI or via kubectl

### Auto-Sync Behavior

- **Enabled by default** for all managed resources
- Changes are applied automatically within 3 minutes
- Failed syncs trigger retries with exponential backoff
- Manual intervention required only for failed syncs

### Pruning Resources

- **Enabled by default**: Resources removed from Git are deleted from clusters
- **Preserves resources on ApplicationSet deletion**: Prevents accidental cleanup
- Use `argocd.argoproj.io/sync-options: Prune=false` annotation to prevent deletion

---

## 🏗️ Architecture Patterns

### Multi-Source Applications

All cluster Applications use ArgoCD's [multi-source feature](https://argo-cd.readthedocs.io/en/stable/user-guide/multiple_sources/):

1. **AppProject source**: Defines RBAC and allowed resources
2. **Component ApplicationSet source**: Auto-discovers addons and workloads
3. **Values overlay**: Cluster-specific Helm values

This pattern enables:
- ✅ Single Application per cluster (simpler management)
- ✅ Automatic component discovery (less YAML)
- ✅ Cluster-specific customization (via values files)

### ApplicationSet Generators

We use [Git File generators](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Git/) to auto-discover clusters:

```yaml
generators:
  - git:
      repoURL: https://github.com/OPerezSandoval/homelab-gitops
      revision: HEAD
      files:
        - path: "kubernetes/cluster-config/*/config.yaml"
```

This automatically creates Applications for any new cluster added to `cluster-config/`.

---

## 🛠️ Common Operations

### Add a New Cluster

1. Create cluster directory:
   ```bash
   mkdir -p kubernetes/cluster-config/new-cluster
   ```

2. Create `config.yaml`:
   ```yaml
   cluster:
     name: new-cluster
     project: my-project
     location: us-east1
     cloudProvider: gcp
     address: https://new-cluster.example.com
   ```

3. Create `appproject.yaml`:
   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: AppProject
   metadata:
     name: new-cluster
     namespace: argocd
   spec:
     destinations:
       - namespace: '*'
         server: 'https://new-cluster.example.com'
     sourceRepos:
       - '*'
   ```

4. Commit and push - ArgoCD will auto-provision the cluster!

### Add Cluster-Specific Values

Create a values file for a specific component:

```bash
# Add custom values for sealed-secrets on prod-us-central1
cat > kubernetes/cluster-config/prod-us-central1/values-sealed-secrets.yaml <<EOF
# Custom configuration for sealed-secrets
replicaCount: 3
resources:
  limits:
    memory: 512Mi
EOF
```

### Remove a Cluster

1. Delete cluster directory:
   ```bash
   rm -rf kubernetes/cluster-config/old-cluster
   ```

2. Commit and push - ApplicationSet will clean up the Application

Note: Resources in the cluster are preserved due to `preserveResourcesOnDeletion: true`

---

## 🔍 Monitoring and Troubleshooting

### View ArgoCD Applications

```bash
# List all Applications
kubectl get applications -n argocd

# Describe specific Application
kubectl describe application <app-name> -n argocd

# Check sync status
argocd app get <app-name>
```

### View ApplicationSets

```bash
# List all ApplicationSets
kubectl get applicationsets -n argocd

# View ApplicationSet details
kubectl describe applicationset <appset-name> -n argocd
```

### Debug Sync Issues

```bash
# View Application events
kubectl describe application <app-name> -n argocd

# Check ArgoCD logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller

# Manual sync
argocd app sync <app-name>

# View sync diff
argocd app diff <app-name>
```

---

## 🎯 Selective Deployment

You don't need to deploy the full cluster bootstrap to use Skyhook. You can selectively deploy individual addons or workloads.

### Deploy Individual Addons

Addons are system-level components like monitoring, secrets management, ingress controllers, etc.

**Structure**: `addons/<addon-name>/<cluster-name>-appset.yaml`

**Example: Deploy only sealed-secrets addon**

```bash
# Apply the sealed-secrets ApplicationSet for your cluster
kubectl apply -f addons/sealed-secrets/prod-us-central1-appset.yaml

# Verify deployment
kubectl get applicationset -n argocd
kubectl get application -n argocd | grep sealed-secrets
```

**Benefits**:
- ✅ Deploy only the addons you need
- ✅ Keep manual control over other infrastructure
- ✅ Gradually migrate to GitOps
- ✅ Mix GitOps and manual management

### Deploy Individual Workloads

Workloads are your applications and services.

**Structure**: `workloads/<workload-name>/<cluster-name>-appset.yaml`

**Example: Deploy only your application workloads**

```bash
# Apply the ApplicationSet for your application
kubectl apply -f workloads/my-app/prod-us-central1-appset.yaml

# Verify deployment
kubectl get applicationset -n argocd
kubectl get application -n argocd | grep my-app
```

**Benefits**:
- ✅ GitOps for applications, manual infrastructure management
- ✅ Separate application deployment from infrastructure
- ✅ Different teams can manage different components
- ✅ Incremental adoption of GitOps

### Deploy Component ApplicationSets Independently

The `bootstrap/cluster-components/` directory contains high-level ApplicationSets that auto-discover components:

```bash
# Deploy only the addons discovery ApplicationSet
kubectl apply -f bootstrap/cluster-components/addons-app.yaml

# Or deploy only the workloads discovery ApplicationSet
kubectl apply -f bootstrap/cluster-components/workloads-app.yaml
```

This approach automatically discovers and deploys all addons or workloads without the full cluster bootstrap.

### Mixed Management Example

**Scenario**: You manage infrastructure manually but want GitOps for applications

```bash
# Manual infrastructure management
# - Manually install monitoring, ingress, secrets management
# - Configure networking, storage, security policies yourself

# GitOps for applications only
kubectl apply -f bootstrap/cluster-components/workloads-app.yaml

# Result:
# - Infrastructure: Manual control
# - Applications: GitOps automation
```

---

## 📚 Additional Resources

- **[ArgoCD Documentation](https://argo-cd.readthedocs.io/)**
- **[ApplicationSet Documentation](https://argo-cd.readthedocs.io/en/stable/user-guide/application-set/)**
- **[ArgoCD Best Practices](https://argo-cd.readthedocs.io/en/stable/user-guide/best_practices/)**
- **[Bootstrapping Instructions](./bootstrap/README.md)**
