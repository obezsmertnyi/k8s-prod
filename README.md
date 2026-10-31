# k8s-prod

Homework for the course "Kubernetes in Production". The lab runs on a local kind cluster. Each module is delivered as one pull request that builds on the previous one:

| Module | Topic |
|---|---|
| 02 | Security and policy as code: namespaces, RBAC, Kyverno policies |
| 03 | GitOps with Flux and Helm charts |
| 04 | Istio service mesh |
| 05 | Observability |

## Prerequisites

- Docker
- kind v0.33.0
- kubectl
- helm v4
- kyverno CLI 1.19
- bash 4 or newer for the scripts. macOS ships `/bin/bash` 3.2, which is too old: install a current bash (`brew install bash`) and make sure it comes first in `PATH`.
- jq and openssl, used by the scripts

## Quick start

```
make up       # kind cluster, Kyverno, namespaces, RBAC, policies, user kubeconfigs, then the checks
make verify   # run the checks again: unit tests, RBAC matrix, policy behaviour on the live cluster
make down     # delete the cluster and the generated kubeconfigs
```

`make` uses its own admin kubeconfig, `out/admin.kubeconfig`, so your default `~/.kube/config` is not touched. To run `kubectl` against the lab by hand, run `export KUBECONFIG=$PWD/out/admin.kubeconfig` first.

## Documentation

- [Module 02: Security and policy as code](docs/module-02.md)

## Security note

`out/` holds private keys and kubeconfigs (the admin one and one per person, each with an embedded client certificate and key). It is git-ignored, together with `*.kubeconfig`. Never commit it or share its contents.
