# Module 03: GitOps with Flux and Helm charts

This page is for the reviewer. It lists what the repository builds for Module 03, the decisions behind it, and the commands that prove each claim.

## What is built

| Task | What exists | Where |
|---|---|---|
| 1. A GitOps system for future changes | Flux, installed by the Flux Operator. A `FluxInstance` points Flux at this repository, path `clusters/k8s-prod`. Two Flux Kustomizations (`infrastructure`, `platform`) apply everything else. Kyverno is a HelmRelease | `clusters/`, `infrastructure/`, `releases/`, `make flux` |
| 2. The Module 02 policies as Helm charts | `charts/tenants` (namespaces, Pod Security labels, RoleBindings) and `charts/kyverno-policies` (the two policies). Each chart is deployed by a HelmRelease that reads the chart from this repository | `charts/`, `releases/` |

After the one-time bootstrap, every change reaches the cluster through Git: edit, commit, push, and Flux applies it. `make up` runs these targets in order:

1. `cluster`: creates the kind cluster.
2. `flux`: installs the Flux Operator, creates the GitHub App secret and applies the `FluxInstance`. This is the only step that is not driven by Git.
3. `wait`: waits until the FluxInstance, the three Kustomizations and the three HelmReleases are Ready.
4. `users`: runs `scripts/make-user.sh` for the mentor and each student.
5. `verify`: runs the checks described below.

## Versions

| Component | Version | Pinned in |
|---|---|---|
| Flux | 2.10.x (v2.10.0 installed) | `clusters/bootstrap/flux-instance.yaml` |
| Flux Operator (Helm chart) | 0.62.1 | `Makefile` (`FLUX_OPERATOR`) |
| Kyverno | 1.19.2 (Helm chart 3.9.2) | `infrastructure/kyverno/release.yaml` |
| Kubernetes | v1.37.0 (kind) | `cluster/kind.yaml` |

Local tools: flux CLI v2.10.0, helm v4.1.3, kubeconform 0.8.0, kyverno CLI 1.19.2.

## Layout

```
clusters/
  bootstrap/flux-instance.yaml   FluxInstance template, applied once by `make flux`
  k8s-prod/                      the path Flux syncs: the two Flux Kustomizations
infrastructure/kyverno/          Namespace, HelmRepository and HelmRelease for Kyverno
releases/                        the HelmReleases of the two local charts
charts/
  tenants/                       namespaces, Pod Security labels, RoleBindings
  kyverno-policies/              require-ro-rootfs and person-label
scripts/wait-flux.sh             waits for the bootstrap to converge
scripts/verify-flux.sh           checks the Flux state, the revision and drift self-heal
```

The order of events on a new cluster:

1. `make flux` creates the `FluxInstance`. The operator installs Flux and creates a GitRepository and a Kustomization, both named `flux-system`, that sync `clusters/k8s-prod`.
2. That path holds two Flux Kustomizations. `infrastructure` applies `infrastructure/`: the `kyverno` namespace, the Kyverno HelmRepository and the Kyverno HelmRelease. It has `wait: true`, so it is Ready only when Kyverno is installed and healthy.
3. `platform` depends on `infrastructure` and applies `releases/`: the HelmReleases `tenants` and `kyverno-policies`. `kyverno-policies` also depends on the `kyverno` HelmRelease, because the policy kinds are Kyverno CRDs.
4. Both HelmReleases take their chart from the GitRepository `flux-system` (`./charts/tenants`, `./charts/kyverno-policies`) with `reconcileStrategy: Revision`. A chart change in Git is deployed without a version bump.

`prune: true` is set on both Kustomizations, so an object removed from Git is removed from the cluster. This includes a whole release: deleting `releases/tenants.yaml` uninstalls the chart and with it the person namespaces.

## Why the Flux Operator and a GitHub App

**Flux Operator.** The `FluxInstance` is one object that declares the Flux version (`2.10.x`) and the sync source. An upgrade is an edit of that version. `flux bootstrap` would commit Flux's own manifests to this repository and needs a token that can write to it; with the operator the cluster never writes to Git.

**GitHub App.** The repository is private, so Flux needs a credential to read it. The App has one permission, Contents read-only, and is installed on this repository only. Flux exchanges the App's private key for installation tokens that expire after an hour. No deploy key and no personal token is stored in the cluster. The only secret is the App's private key in the Secret `flux-system` in the `flux-system` namespace; it is created by `make flux` from `out/`, which is git-ignored, and it is not in Git. To cut Flux off, uninstall the App from the repository.

## Bootstrap is the only imperative step

`make flux` does three things and nothing else:

1. `helm upgrade --install flux-operator` (chart 0.62.1) into `flux-system`.
2. `flux create secret githubapp flux-system`, from the settings in `out/flux-app.env` (see the README for the one-time App setup).
3. Applies `clusters/bootstrap/flux-instance.yaml` with the branch filled in.

The branch Flux follows is a parameter: `BRANCH ?= $(shell git rev-parse --abbrev-ref HEAD)`. Until the module pull requests are merged the cluster follows the top branch (`module-03`). After the merge, run `make flux BRANCH=main` and the cluster follows `main`. The command is safe to repeat.

## The charts

### tenants

Namespaces (with the `k8s-prod.io/role` label and the Pod Security labels) and the RoleBindings to the built-in `edit` and `view` ClusterRoles, all generated from `charts/tenants/values.yaml`:

| Value | Default | Effect |
|---|---|---|
| `mentor` | `mentor` | a user and namespace of that name; `edit` in every person namespace |
| `students` | `student01`, `student02`, `student03` | a user and namespace each; `edit` in their own namespace |
| `extraGrants` | student02: `view` in `student01` and `default` | RoleBindings outside a person's own namespace |
| `podSecurity` | enforce `baseline`, warn and audit `restricted`, version `v1.37` | the labels on every person namespace |
| `roleLabel` | `k8s-prod.io/role` | namespace label the policies select on |

The defaults render exactly what Module 02 applied: 4 Namespaces and 9 RoleBindings with the same names, labels, roles and subjects. Adding a student or a read grant is a change to `values.yaml`.

### kyverno-policies

The `ValidatingPolicy` `require-ro-rootfs` and the `MutatingPolicy` `person-label`, copied from Module 02 and templated only where a value is useful:

| Value | Default | Used by |
|---|---|---|
| `roleLabel` | `k8s-prod.io/role` | `person-label`: the namespace label the role is read from |
| `validationActions` | `[Audit]` | `require-ro-rootfs`: Audit records findings, `[Deny]` would block |
| `excludedNamespaces` | `kube-system`, `kube-public`, `kube-node-lease`, `kyverno`, `local-path-storage` | `require-ro-rootfs`: namespaces left out of the report |

The rendered policies are the same objects as in Module 02. To compare, with `yq` and `jq` installed and the `module-02` branch present:

```
make render
sorted() { yq -o=json . | jq -S -s -c 'sort_by(.kind, .metadata.namespace, .metadata.name)'; }
cmp <(helm template tenants charts/tenants | sorted) \
    <({ git show module-02:platform/namespaces.yaml; echo ---; git show module-02:platform/rbac.yaml; } | sorted) && echo identical
for p in require-ro-rootfs person-label; do
  cmp <(sorted < .rendered/kyverno-policies/templates/$p.yaml) <(git show module-02:platform/policies/$p.yaml | sorted) && echo identical
done
```

All three print `identical`. As text the policies differ in the generated header only, plus two lists that Helm writes as JSON instead of YAML flow style:

```
$ git show module-02:platform/policies/require-ro-rootfs.yaml | diff - .rendered/kyverno-policies/templates/require-ro-rootfs.yaml
0a1,2
> ---
> # Source: kyverno-policies/templates/require-ro-rootfs.yaml
7c9
<   validationActions: [Audit]
---
>   validationActions: ["Audit"]
22c24
<           values: [kube-system, kube-public, kube-node-lease, kyverno, local-path-storage]
---
>           values: ["kube-system","kube-public","kube-node-lease","kyverno","local-path-storage"]
```

`person-label` differs in the header only.

## How to verify

One command, from the repository root, after `make up`:

```
make verify
```

It runs the steps below and stops at the first failing step. They can be run on their own. Run `export KUBECONFIG=$PWD/out/admin.kubeconfig` first for the scripts and for `kubectl`.

| Step | Command | What it proves |
|---|---|---|
| Chart lint | `make lint` | `helm lint` on both charts; `kubeconform -strict` on the rendered charts, on `infrastructure/`, on `releases/` and on `clusters/`. Every kind has a schema (the datree CRDs catalog covers the Kyverno and Flux kinds), so none is skipped: the summary lines end with `Skipped: 0` |
| Policy unit tests | `make test` | renders `charts/kyverno-policies` into `.rendered/` (git-ignored) and runs `kyverno test tests/kyverno` on that output, so the tests check what the chart renders |
| RBAC matrix | `scripts/verify-rbac.sh` | the Module 02 checks, now on the objects Flux deploys |
| Policy behaviour | `scripts/verify-policies.sh` | the Module 02 checks, now on the policies Flux deploys |
| Flux state | `scripts/verify-flux.sh` | the checks listed below |

`make lint` is not part of `make verify`: it downloads schemas from GitHub.

`scripts/verify-flux.sh` checks:

- The FluxInstance, the three Kustomizations and the three HelmReleases are Ready, and no other Kustomization or HelmRelease is not Ready.
- The GitRepository `flux-system` is at the head of the branch it follows. The script asks Flux to fetch, then compares with `git ls-remote origin <ref>`.
- Drift self-heal: it deletes the RoleBinding `student01-edit` in `student01` with the admin kubeconfig, runs `flux reconcile helmrelease tenants --force`, and requires the binding back with the role `edit` for `student01`. The delete is skipped when an earlier check failed, because then nothing would put the binding back.

Each script exits non-zero if any answer differs from the expected one.

To see a change flow through Git, edit `charts/tenants/values.yaml` (for example add a read grant under `extraGrants`), commit and push, then:

```
flux reconcile source git flux-system -n flux-system
flux get helmrelease tenants -n flux-system
kubectl get rolebinding -A | grep student
```

Without the manual reconcile Flux picks the change up within the sync interval.

Useful commands to look at the system:

```
kubectl get fluxinstance,gitrepository,kustomization,helmrelease -n flux-system
flux get kustomizations -n flux-system
flux get helmreleases -n flux-system
```

## Things to know

- **Drift detection** is on for `tenants` and `kyverno-policies` (`driftDetection.mode: enabled`). Without it, helm-controller only acts when the chart, the values or a forced reconcile say so, and an object deleted by hand would stay deleted until the next change. With it, the next reconcile puts the object back. Both releases reconcile every 10 minutes.
- **The Flux namespace.** None of the nine RoleBindings is in `flux-system`, so no person has a right there.
- **Module 02 targets.** The `kyverno` and `platform` make targets and the `platform/` directory are gone: Helm releases that Flux manages replaced them.

## Live run

The lab was rebuilt from zero with `make down && make up` (exit 0): the cluster follows `refs/heads/module-03` at `5bf15f2`, everything came from Git, and the log holds 159 `ok` lines.

### make up

```
Flux: everything is Ready
Test Summary: 13 tests passed and 0 tests failed
RBAC: all checks passed
Policies: all checks passed
Flux: all checks passed
```

### Flux state

```
$ flux get kustomizations -A
NAMESPACE    NAME            REVISION                            SUSPENDED  READY  MESSAGE
flux-system  flux-system     refs/heads/module-03@sha1:5bf15f28  False      True   Applied revision: refs/heads/module-03@sha1:5bf15f28
flux-system  infrastructure  refs/heads/module-03@sha1:5bf15f28  False      True   Applied revision: refs/heads/module-03@sha1:5bf15f28
flux-system  platform        refs/heads/module-03@sha1:5bf15f28  False      True   Applied revision: refs/heads/module-03@sha1:5bf15f28

$ flux get helmreleases -A
NAMESPACE    NAME              REVISION            SUSPENDED  READY  MESSAGE
flux-system  kyverno           3.9.2               False      True   Helm install succeeded for release kyverno/kyverno.v1 with chart kyverno@3.9.2
flux-system  kyverno-policies  0.1.0+5bf15f283c1b  False      True   Helm install succeeded for release flux-system/kyverno-policies.v1 with chart kyverno-policies@0.1.0+5bf15f283c1b
flux-system  tenants           0.1.0+5bf15f283c1b  False      True   Helm install succeeded for release flux-system/tenants.v1 with chart tenants@0.1.0+5bf15f283c1b

$ kubectl get fluxinstance -n flux-system
NAME   AGE     READY   STATUS                             REVISION
flux   8m45s   True    Reconciliation finished in 1m25s   v2.10.0@sha256:94bda7818110a743279dcc03cc80341ce399c9fc81e0e043444e6feb3787805d

$ kubectl get policyreport -n flux-system -o custom-columns=NAME:.scope.name,PASS:.summary.pass,FAIL:.summary.fail
NAME                                       PASS   FAIL
notification-controller-7df89fc4ff         1      0
source-controller-6bf94f6c78               1      0
kustomize-controller-57f9457655-zmdwc      2      0
source-controller                          1      0
kustomize-controller                       1      0
kustomize-controller-57f9457655            1      0
helm-controller-7b45f6fcd                  1      0
notification-controller-7df89fc4ff-xgd2x   2      0
flux-operator-784b66fbc5-h2jt2             2      0
flux-operator                              1      0
notification-controller                    1      0
source-controller-6bf94f6c78-gt2tq         2      0
helm-controller                            1      0
helm-controller-7b45f6fcd-zxz2t            2      0
flux-operator-784b66fbc5                   1      0
```

### scripts/verify-flux.sh

```
scripts/verify-flux.sh
== flux objects
  ok    fluxinstance/flux is Ready                                 True
  ok    kustomization/flux-system is Ready                         True
  ok    kustomization/infrastructure is Ready                      True
  ok    kustomization/platform is Ready                            True
  ok    helmrelease/kyverno is Ready                               True
  ok    helmrelease/tenants is Ready                               True
  ok    helmrelease/kyverno-policies is Ready                      True
  ok    every other Kustomization and HelmRelease is Ready
== git revision
  ok    GitRepository flux-system is at the head of refs/heads/module-03 5bf15f283c1bcd9c71eafe94cf94af950b1c62fd
== drift self-heal
  ok    student01-edit in student01 is deleted
  ok    student01-edit is back after the reconcile (role subject)  edit student01
Flux: all checks passed
```

The RoleBinding `student01-edit` was deleted by hand, and after `flux reconcile helmrelease tenants --force` it was back with the role `edit` for `student01`, so drift detection restored it.
