# Homelab Cluster GitOps

This directory contains the GitOps configuration for the homelab Talos cluster.

## 🚀 **Fully Automated Bootstrap**

When the worker node provisions, the following happens automatically:

1. **FluxCD** is installed via `extraManifests`
2. **External Secrets Operator** is installed via `extraManifests` 
3. **1Password Connect token** is created and stored by setup script
4. **SecretStore** connects to 1Password Homelab vault
5. **SSH key** is pulled from 1Password for Git access
6. **GitRepository** points to `git@github.com:tkuipers/homelab.git`
7. **Kustomization** syncs this `clusters/homelab/` directory

## 📁 **Directory Structure**

```
clusters/homelab/
├── kustomization.yaml           # Main kustomization
├── infrastructure/              # Core cluster services
│   └── kustomization.yaml
├── apps/                       # Applications
│   └── kustomization.yaml
└── flux-system/                # FluxCD resources (optional)
```

## ✅ **What Works Automatically**

- **Secret Management**: External Secrets Operator pulls secrets from 1Password
- **GitOps**: FluxCD monitors this repo and applies changes automatically
- **Infrastructure**: Add services to `infrastructure/` directory
- **Applications**: Add apps to `apps/` directory

## 🔄 **Adding New Components**

1. Create a new directory under `infrastructure/` or `apps/`
2. Add Kubernetes manifests or Helm releases
3. Reference it in the appropriate `kustomization.yaml`
4. Commit and push - FluxCD will apply automatically!

## 🔒 **Secret Management**

Store secrets in 1Password Homelab vault, then create `ExternalSecret` resources:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: my-app-secret
spec:
  secretStoreRef:
    name: onepassword-store
    kind: SecretStore
  target:
    name: my-app-secret
  dataFrom:
    - extract:
        key: "My App Credentials"
``` 