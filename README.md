# okd-prod

GitOps repository for the production OKD cluster, managed with Argo CD.

## Repository layout

- `clusters/okd-prod/`: cluster-level manifests and `kustomization.yaml`.

## What this repository contains

This repo tracks Kubernetes/OpenShift manifests for:

- Red Hat Advanced Cluster Management operator and hub configuration
- local storage operator and volumes
- storage classes and storage cluster configuration
- cert-manager issuers and certificates
- Red Hat Advanced Cluster Security operator and central services
- console plugin configuration
- machine configuration objects

## Validate changes locally

From the repository root:

```bash
yamllint -d "{extends: default, rules: {line-length: disable, document-start: disable}}" .
kustomize build clusters/okd-prod
```

These commands match the validation checks used in CI.
