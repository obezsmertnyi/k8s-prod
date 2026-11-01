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
- flux CLI 2.10 and kubeconform 0.8 (the second one only for `make lint`)
- istioctl 1.31, used by `make verify` (`scripts/verify-mesh.sh`)
- bash 4 or newer for the scripts. macOS ships `/bin/bash` 3.2, which is too old: install a current bash (`brew install bash`) and make sure it comes first in `PATH`.
- jq and openssl, used by the scripts

## One-time setup: a GitHub App for Flux

The repository is private. Flux reads it with a GitHub App, so no deploy key or personal token goes into the cluster.

1. Create a GitHub App (Settings, Developer settings, GitHub Apps) with the repository permission Contents set to read-only. Leave the webhook inactive.
2. Install the App on this repository only.
3. Generate a private key for the App and save the `.pem` file as `out/flux-github-app.pem`.
4. Create `out/flux-app.env`:

```
FLUX_APP_CLIENT_ID=<client ID of the App>
FLUX_APP_OWNER=<account that owns the repository>
FLUX_APP_KEY=out/flux-github-app.pem
```

`make flux` reads this file. `out/` is git-ignored.

## Quick start

```
make up       # kind cluster, Flux, then Flux deploys Kyverno, Istio, namespaces, RBAC and policies from Git; user kubeconfigs; the checks
make verify   # run the checks again: unit tests, RBAC matrix, policy behaviour, the mesh, Flux state
make lint     # helm lint and kubeconform on the charts and the Flux manifests
make down     # delete the cluster and the generated kubeconfigs
```

Flux reads the cluster state from GitHub, so the branch you are on must be pushed before `make up`. Flux follows the current branch. To follow another one, for example after the pull requests are merged, run `make flux BRANCH=main`.

`make` uses its own admin kubeconfig, `out/admin.kubeconfig`, so your default `~/.kube/config` is not touched. To run `kubectl` against the lab by hand, run `export KUBECONFIG=$PWD/out/admin.kubeconfig` first.

## Documentation

- [Module 02: Security and policy as code](docs/module-02.md)
- [Module 03: GitOps with Flux and Helm charts](docs/module-03.md)
- [Module 04: Istio service mesh](docs/module-04.md)

## Security note

`out/` holds private keys and kubeconfigs (the admin one and one per person, each with an embedded client certificate and key) and the GitHub App private key for Flux. It is git-ignored, together with `*.kubeconfig`. Never commit it or share its contents.
