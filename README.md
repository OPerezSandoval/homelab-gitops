# Homelab GitOps

GitOps repo for a Talos Kubernetes cluster. Uses Helm and Kustomize for manifests, ArgoCD for automatic deployments.

## Structure

- `clusters/` - Talos cluster configs (dev & prod)
- `kubernetes/apps/base/` - Base app manifests
- `kubernetes/apps/overlays/` - Environment-specific overrides
- `argocd-bootstrap/` - ArgoCD installation

Push a change and ArgoCD syncs it to the cluster.