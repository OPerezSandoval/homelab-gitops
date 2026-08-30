# ArgoCD Installation (Individual Clusters)

This Helm chart installs ArgoCD with per-cluster configurations.

## Chart Details

- **Chart**: argo-cd
- **Version**: 9.3.5
- **Repository**: https://argoproj.github.io/argo-helm

## Structure

- `Chart.yaml` - Base chart definition
- `values.yaml` - Base values (shared across clusters)
- `{cluster-name}/` - Cluster-specific overrides
