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
- flux CLI 2.10, with the schema plugin for `make lint` (`flux plugin install schema`, flux-schema 0.17)
- istioctl 1.31, used by `make verify` (`scripts/verify-mesh.sh`)
- bash 4 or newer for the scripts. macOS ships `/bin/bash` 3.2, which is too old: install a current bash (`brew install bash`) and make sure it comes first in `PATH`.
- jq and openssl, used by the scripts (jq also by `make lint`)

## Optional setup: a GitHub App for Flux

For a public repository Flux needs no credentials, and `make up` works from a plain clone with nothing set up. Without `out/flux-app.env`, `make flux` prints `no out/flux-app.env: public repository, Flux reads it without credentials`, creates no secret and applies the FluxInstance without `provider` and `pullSecret`, so Flux reads the repository over anonymous HTTPS.

The GitHub App is only for a private repository, or to avoid anonymous rate limits. Flux then reads the repository with the App, so no deploy key or personal token goes into the cluster.

1. Create a GitHub App (Settings, Developer settings, GitHub Apps) with the repository permission Contents set to read-only. Leave the webhook inactive.
2. Install the App on this repository only.
3. Generate a private key for the App and save the `.pem` file as `out/flux-github-app.pem`.
4. Create `out/flux-app.env`:

```
FLUX_APP_CLIENT_ID=<client ID of the App>
FLUX_APP_OWNER=<account that owns the repository>
FLUX_APP_KEY=out/flux-github-app.pem
```

`make flux` uses the App when this file exists. `out/` is git-ignored.

5. Optional, for Module 05: create `out/lab.env` with the address the alert email goes to (`ALERT_EMAIL=you@example.com`). `make flux` turns it into the Secret `lab-settings`, from which Flux fills `${ALERT_EMAIL}` in the Alertmanager config, so the address never enters Git. Without it the alerts go to `alerts@k8s-prod.lab`; either way Mailpit catches them inside the cluster.

## Quick start

```
make up       # kind cluster, Flux, then Flux deploys Kyverno, Istio, the monitoring stack, namespaces, RBAC, policies and dashboards from Git; user kubeconfigs; the checks
make verify   # run the checks again: unit tests, RBAC matrix, policy behaviour, the mesh, observability, Flux state
make lint     # helm lint, then flux-schema on the rendered charts and Flux manifests (schemas and CEL rules), JSON check of the dashboards
make down     # delete the cluster and the generated kubeconfigs
```

Flux reads the cluster state from GitHub, so the branch you are on must be pushed before `make up`. Flux follows the current branch of the repository in your `origin` remote (`git@github.com:<owner>/<repo>.git` and `https://` forms both become `https://github.com/<owner>/<repo>.git`). To follow another branch, for example after the pull requests are merged, run `make flux BRANCH=main`; for another repository, `make flux REPO_URL=https://github.com/<owner>/<repo>.git`.

`make` uses its own admin kubeconfig, `out/admin.kubeconfig`, so your default `~/.kube/config` is not touched. To run `kubectl` against the lab by hand, run `export KUBECONFIG=$PWD/out/admin.kubeconfig` first.

## Documentation

- [Module 02: Security and policy as code](docs/module-02.md)
- [Module 03: GitOps with Flux and Helm charts](docs/module-03.md)
- [Module 04: Istio service mesh](docs/module-04.md)
- [Module 05: Observability and troubleshooting](docs/module-05.md)

## Security

What runs where:

- On your machine, after `pre-commit install` (once per clone). On every commit: checks for private keys, merge markers, large files, YAML syntax, shellcheck on `scripts/`, zizmor on the GitHub Actions files, and gitleaks on the staged changes (`.gitleaks.toml` adds a rule for kubeconfig `client-key-data`). On every push: `scripts/validate-manifests.sh` renders the charts and Flux manifests and checks them against the schemas, and the Kyverno unit tests run when charts or tests changed. The script needs helm, flux-schema (`flux plugin install schema`) and network access for the schemas.
- On GitHub, for every push and pull request (`.github/workflows/ci.yml`): gitleaks over the whole history, all pre-commit hooks on all files, the manifest validation and the policy tests. Actions are pinned to full commit SHAs, and the tools CI downloads are checked against hashes kept in the workflow.
- Dependabot opens one weekly pull request for new action versions and one for new pre-commit hook versions.

`out/` holds private keys and kubeconfigs (the admin one and one per person, each with an embedded client certificate and key) and, if you use one, the GitHub App private key for Flux. It is git-ignored, together with `*.kubeconfig`. Never commit it or share its contents.

If a secret leaks (committed, pushed, pasted into a chat or a log), treat it as compromised and rotate it first. Removing it from the Git history afterwards is cleanup only, it does not make the old secret safe.

- User kubeconfig: delete the user's key (`rm out/kubeconfigs/keys/<user>.key`), then run `make users`. Without deleting the key, `make users` reuses it and only issues a new certificate. Kubernetes cannot revoke a client certificate, so the old one works until it expires (30 days). To cut it off at once, remove that user's RoleBindings or recreate the lab (`make down`, `make up`).
- GitHub App key (only if you use the App): in the App settings generate a new private key and save it as `out/flux-github-app.pem`, run `make flux` to update the secret in the cluster, then delete the old key in the App settings.
- Any other key in `out/`, for example an SSH key: generate a new one, register the new public key where the old one was, then remove the old one.
