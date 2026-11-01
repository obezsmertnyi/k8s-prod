# k8s-prod

Homework for the course "Kubernetes in Production". Each module arrives as a pull request.

## Security

What runs where:

- On your machine, after `pre-commit install` (once per clone). On every commit: checks for private keys, merge markers, large files, YAML syntax, shellcheck on `scripts/`, zizmor on the GitHub Actions files, and gitleaks on the staged changes (`.gitleaks.toml` adds a rule for kubeconfig `client-key-data`). On every push: `scripts/validate-manifests.sh` renders the charts and Flux manifests and checks them against the schemas, and the Kyverno unit tests run when charts or tests changed. The script needs helm, flux-schema (`flux plugin install schema`) and network access for the schemas.
- On GitHub, for every push and pull request (`.github/workflows/ci.yml`): gitleaks over the whole history, all pre-commit hooks on all files, the manifest validation and the policy tests. Actions are pinned to full commit SHAs, and the tools CI downloads are checked against hashes kept in the workflow.
- Dependabot opens one weekly pull request for new action versions and one for new pre-commit hook versions.

`out/` holds private keys and kubeconfigs (the admin one and one per person, each with an embedded client certificate and key) and the GitHub App private key for Flux. It is git-ignored, together with `*.kubeconfig`. Never commit it or share its contents.

If a secret leaks (committed, pushed, pasted into a chat or a log), treat it as compromised and rotate it first. Removing it from the Git history afterwards is cleanup only, it does not make the old secret safe.

- User kubeconfig: delete the user's key (`rm out/kubeconfigs/keys/<user>.key`), then run `make users`. Without deleting the key, `make users` reuses it and only issues a new certificate. Kubernetes cannot revoke a client certificate, so the old one works until it expires (30 days). To cut it off at once, remove that user's RoleBindings or recreate the lab (`make down`, `make up`).
- GitHub App key: in the App settings generate a new private key and save it as `out/flux-github-app.pem`, run `make flux` to update the secret in the cluster, then delete the old key in the App settings.
- Any other key in `out/`, for example an SSH key: generate a new one, register the new public key where the old one was, then remove the old one.
