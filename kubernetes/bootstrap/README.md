# ArgoCD Bootstrap

This directory contains the bootstrap ApplicationSets for deploying ArgoCD resources across your infrastructure.

## Architecture Decision: Choose Your Deployment Model

You need to choose between **two supported ArgoCD architectures** based on your infrastructure requirements:

### Option 1: Centralized Management (Single ArgoCD)

**Description**: Use a single ArgoCD instance to manage all clusters from one central location.

**How it works**:
- One ArgoCD instance runs on a management cluster
- This ArgoCD instance manages applications across all clusters (including itself)
- All clusters are registered as remote clusters in the central ArgoCD
- ApplicationSets automatically discover and deploy to all clusters

**Advantages**:
- ✅ Centralized visibility: Single pane of glass for all clusters
- ✅ Easier management: One ArgoCD to configure and maintain
- ✅ Simplified RBAC: Manage permissions in one place
- ✅ Better for multi-tenant scenarios
- ✅ Easier to implement progressive rollouts across clusters

**Considerations**:
- Requires network connectivity from management cluster to all target clusters
- Single point of failure (mitigated with ArgoCD HA setup)
- Requires credentials for all clusters to be stored in the management cluster
- May have higher latency for clusters in different regions

**Use this if**:
- You have a management/hub cluster
- You need centralized control and visibility
- You're managing multiple clusters as a platform team
- You want to implement cluster-wide policies

**Deployment folder**: `auto-provision-clusters/`

---

### Option 2: Distributed Management (Multiple Standalone ArgoCD)

**Description**: Each cluster runs its own ArgoCD instance that manages only itself.

**How it works**:
- Each cluster has its own dedicated ArgoCD instance
- Each ArgoCD instance only manages resources in its own cluster
- No cross-cluster communication required
- Each cluster is independently managed

**Advantages**:
- ✅ Complete isolation: Clusters are independent
- ✅ No single point of failure across clusters
- ✅ Better for compliance: Each cluster can have isolated security boundaries
- ✅ Works with disconnected/air-gapped clusters
- ✅ Lower latency: ArgoCD runs locally in each cluster
- ✅ Simpler credential management: No cross-cluster credentials needed

**Considerations**:
- More ArgoCD instances to maintain and upgrade
- No centralized visibility (requires additional tooling)
- RBAC must be configured in each cluster
- Harder to implement consistent policies across clusters

**Use this if**:
- You need strong cluster isolation
- You have compliance/security requirements for isolation
- Your clusters are in different networks or air-gapped
- Each cluster is managed by a different team
- You want to minimize blast radius of issues

**Deployment folder**: `individual-clusters/`

---

## Directory Structure

```
bootstrap/
├── README.md                          # This file
├── auto-provision-clusters/           # Option 1: Centralized management
│   └── cluster-appprojects-appset.yaml
├── individual-clusters/               # Option 2: Distributed management
│   ├── taloscluster-appset.yaml
└── cluster-components/                # Component ApplicationSets
    ├── addons-app.yaml                # Discovers addons per cluster
    └── workloads-app.yaml             # Discovers workloads per cluster
```

---

## Deployment Instructions

### Prerequisites

1. Ensure `kubectl` is installed and configured
2. Ensure you have admin access to your cluster(s)
3. Ensure ArgoCD is installed in the target cluster(s)
4. Ensure this Git repository is accessible from your cluster(s)

### Option 1: Centralized Management Deployment

Deploy the single auto-provision ApplicationSet to your **management cluster**:

```bash
# Switch to your management cluster context
kubectl config use-context <management-cluster-context>

# Verify ArgoCD is running
kubectl get pods -n argocd

# Deploy the auto-provision ApplicationSet
kubectl apply -f bootstrap/auto-provision-clusters/cluster-appprojects-appset.yaml

# Verify the ApplicationSet was created
kubectl get applicationset -n argocd cluster-appprojects

# Watch as Applications are created for each cluster
kubectl get applications -n argocd -w
```

**What happens next**:
1. The ApplicationSet scans bootstrap/individual-clusters/
2. Creates one Application per cluster ApplicationSet discovered
3. Each Application deploys its cluster ApplicationSet
4. Each cluster ApplicationSet uses multiple sources to deploy:
   - AppProject for the cluster
   - Component ApplicationSets (addons, workloads)
5. Your infrastructure is fully bootstrapped and ready

### Option 2: Distributed Management Deployment

Deploy individual ApplicationSets to **each cluster separately**:


**Deploy to taloscluster:**

```bash
# Switch to taloscluster cluster context
kubectl config use-context <taloscluster-context>

# Verify ArgoCD is running
kubectl get pods -n argocd

# Deploy the cluster-specific ApplicationSet
kubectl apply -f bootstrap/individual-clusters/taloscluster-appset.yaml

# Verify the ApplicationSet was created
kubectl get applicationset -n argocd taloscluster-cluster-project

# Verify the Application was created
kubectl get application -n argocd taloscluster-cluster-project
```


**What happens next**:
1. Each ApplicationSet creates a single Application named `{cluster}-cluster-project`
2. The Application deploys from multiple sources:
   - AppProject for the cluster
   - Component ApplicationSets (addons and workloads)
3. Component ApplicationSets automatically discover cluster-specific components
4. Your cluster is fully bootstrapped and ready

**Note**: Unlike centralized management, components are automatically deployed with the cluster ApplicationSet. No additional steps needed!

---

## Verification

### Check ApplicationSets

```bash
kubectl get applicationsets -n argocd
```

### Check Applications

```bash
kubectl get applications -n argocd
```

### Check AppProjects

```bash
kubectl get appprojects -n argocd
```

### View ApplicationSet Details

```bash
kubectl describe applicationset -n argocd <applicationset-name>
```

---

## Troubleshooting

### ApplicationSet not creating Applications

Check the ApplicationSet status:
```bash
kubectl describe applicationset -n argocd <applicationset-name>
```

Check ArgoCD ApplicationSet controller logs:
```bash
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-applicationset-controller
```

### Application stuck in Progressing state

Check the Application details:
```bash
kubectl describe application -n argocd <application-name>
```

Check sync status:
```bash
kubectl get application -n argocd <application-name> -o jsonpath='{.status.sync.status}'
```

### Missing cluster config files

Ensure cluster configuration files exist:
```bash
ls -la cluster-config/
```

Each cluster should have:
- `cluster-config/<cluster-name>/config.yaml`
- `cluster-config/<cluster-name>/appproject.yaml`

---

## Migration Between Architectures

### From Distributed to Centralized

1. Delete individual ApplicationSets from each cluster:
   ```bash
   kubectl delete -f bootstrap/individual-clusters/
   ```

2. Register all clusters in your management cluster's ArgoCD

3. Deploy the auto-provision ApplicationSet on management cluster:
   ```bash
   kubectl apply -f bootstrap/auto-provision-clusters/cluster-appprojects-appset.yaml
   ```

### From Centralized to Distributed

1. Delete the auto-provision ApplicationSet from management cluster:
   ```bash
   kubectl delete -f bootstrap/auto-provision-clusters/cluster-appprojects-appset.yaml
   ```

2. Install ArgoCD on each cluster if not already present

3. Deploy individual ApplicationSets to each cluster as described in Option 2 above

---

## Additional Resources

- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [ApplicationSet Documentation](https://argo-cd.readthedocs.io/en/stable/user-guide/application-set/)
- [Multi-Source Applications](https://argo-cd.readthedocs.io/en/stable/user-guide/multiple_sources/)
