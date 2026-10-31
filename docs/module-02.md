# Module 02: Security and policy as code

This page is for the reviewer. It lists what the repository builds for Module 02, the decisions behind it, and the commands that prove each claim.

Since Module 03 the files under `platform/` live in the Helm charts `charts/tenants` and `charts/kyverno-policies` and are deployed by Flux, see [Module 03](module-03.md). This page describes Module 02 as delivered: paths such as `platform/namespaces.yaml` and the `kyverno` and `platform` make targets refer to that state.

## What is built

| Task | What exists | Where |
|---|---|---|
| 1. Cluster, namespaces, kubeconfigs, RBAC | kind cluster `k8s-prod` (1 control plane, 3 workers); namespaces `mentor`, `student01`, `student02`, `student03`; one kubeconfig per person; 9 RoleBindings; Pod Security labels on the four person namespaces | `cluster/kind.yaml`, `platform/namespaces.yaml`, `platform/rbac.yaml`, `scripts/make-user.sh` |
| 2. Readonly root filesystem, audit mode | ValidatingPolicy `require-ro-rootfs` with action Audit | `platform/policies/require-ro-rootfs.yaml` |
| 3. `person` label on pods | MutatingPolicy `person-label` | `platform/policies/person-label.yaml` |

`make up` runs these targets in order:

1. `cluster`: creates the kind cluster.
2. `kyverno`: installs Kyverno with Helm.
3. `platform`: `kubectl apply -k platform/` (namespaces, RBAC, both policies).
4. `users`: runs `scripts/make-user.sh` for the mentor and each student.
5. `verify`: runs the checks described below.

The four kubeconfigs are `out/kubeconfigs/<user>.kubeconfig`, each with the person's own namespace as the default. The cluster admin kubeconfig, `out/admin.kubeconfig`, is used by `make` and the verify scripts. It belongs to the operator of the lab, not to any of the four people.

## Versions

| Component | Version | Pinned in |
|---|---|---|
| Kubernetes | v1.37.0 (`kindest/node`, pinned by digest) | `cluster/kind.yaml` |
| kind | v0.33.0 | local tool |
| Kyverno | 1.19.2 (Helm chart 3.9.2) | `Makefile` (`KYVERNO_CHART`) |

## Identities

Kubernetes has no user objects. A user is whoever presents a credential the API server trusts. Here every person gets a client certificate signed by the cluster CA through the Kubernetes CSR API, by `scripts/make-user.sh <user> <group> <namespace>`:

| Property | Value |
|---|---|
| Subject | `CN=<user>`, `O=<group>` (`mentors` for the mentor, `students` for the students) |
| Key | P-256, generated locally with openssl; only the CSR goes to the API |
| Signer | `kubernetes.io/kube-apiserver-client`, approved with `kubectl certificate approve` |
| Lifetime | 30 days (`expirationSeconds` in the CSR) |
| Files | key in `out/kubeconfigs/keys/` (mode 600), kubeconfig with the certificate and key embedded (mode 600) |

Running `make users` again keeps the keys and issues new certificates, which is how a kubeconfig is renewed.

Bindings name users. The groups are in the certificate (`kubectl auth whoami` shows them) but no binding refers to them.

**Why not ServiceAccounts.** A ServiceAccount is a workload identity: it is for pods that call the API. People are not workloads, and ServiceAccount tokens are not meant to be handed out as personal logins.

**OIDC is the production way.** Users sign in against an identity provider, tokens are short-lived, groups come from the provider, and offboarding happens in one place. Client certificates are used here because they need nothing beyond the cluster itself.

**Certificates cannot be revoked.** The API server does not check a revocation list, so a leaked kubeconfig works until the certificate expires. That is why the lifetime is short. To cut a person off earlier, delete their RoleBindings: the certificate still authenticates, but the identity has no rights. Treat a kubeconfig like a password.

## RBAC

Access is granted only through RoleBindings to the built-in ClusterRoles `edit` (read-write) and `view` (read-only).

| Person | `edit` in | `view` in |
|---|---|---|
| mentor | `mentor`, `student01`, `student02`, `student03` | none |
| student01 | `student01` | none |
| student02 | `student02` | `student01`, `default` |
| student03 | `student03` | none |

student02 also gets `edit` in its own namespace. The task lists only its read grants, but without a grant in its own namespace the namespace would be unusable by its owner. This is a deliberate choice.

Properties that matter for the review:

- No ClusterRoleBinding names a person or one of the two groups. Nobody has cluster-admin, and nobody has any cluster-scoped right (nodes, namespaces, ClusterRoleBindings).
- `edit` cannot create or change Roles and RoleBindings, so nobody can grant themselves more. `view` does not include Secrets.
- The mentor has no rights in `default` or `kube-system`. Each student has none outside the namespaces listed above.

## Pod Security

`edit` includes creating pods, and without Pod Security admission a pod may be privileged or mount the node's filesystem with `hostPath`. Such a pod, optionally pinned to the control-plane node with `nodeName` and a toleration, can read the node's admin credentials and make its creator cluster-admin, although no binding says so.

The four namespaces `mentor`, `student01`, `student02` and `student03` carry these labels (`platform/namespaces.yaml`):

| Label | Value |
|---|---|
| `pod-security.kubernetes.io/enforce` | `baseline` |
| `pod-security.kubernetes.io/warn`, `pod-security.kubernetes.io/audit` | `restricted` |
| the matching `-version` label of each | `v1.37` |

**Why baseline and not restricted.** Baseline rejects privileged containers, `hostPath` volumes, host namespaces (`hostNetwork`, `hostPID`, `hostIPC`), host ports and added capabilities. That closes every route from a pod to the node, and ordinary pods still pass. Restricted would also reject every pod without a full `securityContext` (non-root, all capabilities dropped, a seccomp profile), so the plain `busybox` pods of this lab would stop working. Restricted is set as `warn` and `audit` only: `kubectl` prints a warning when a pod would not pass it, and nothing is blocked. The version labels pin the rules to Kubernetes v1.37, so a cluster upgrade does not change them silently.

`default` and the system namespaces are not labelled. No person can create pods there: student02 has only `view` in `default`.

**Students cannot relax the labels.** They sit on the Namespace object, which is cluster-scoped. `edit` in a namespace gives no right to change that Namespace, so `kubectl label namespace student01 pod-security.kubernetes.io/enforce=privileged --overwrite` is forbidden for student01. Only the cluster admin can change the labels, by editing `platform/namespaces.yaml` and applying it.

`scripts/verify-rbac.sh` checks this with student01's own kubeconfig in `student01`. student01 has `edit` there, so a denial can only come from Pod Security, and the script requires the error text to contain `PodSecurity`, not only `forbidden`. The hostPath pod mounts `/` and is pinned to the control-plane node with a toleration. Denied pods are rejected with messages like:

```
pods "x" is forbidden: violates PodSecurity "baseline:v1.37": privileged (container "c" must not set securityContext.privileged=true)
```

The ordinary pod is admitted with only the restricted warning, and all pods the script creates are deleted. It also reads the `enforce` label of `mentor`, `student01`, `student02` and `student03` with the admin kubeconfig, so dropping the label from any of the four fails the script. The relabel check is a server-side dry run, so a failing check cannot leave the namespace relaxed. The new lines from a real run:

```
== pod security
  ok    student01 creates a privileged pod                         denied
  ok    student01 creates a hostPath / pod on the control plane    denied
  ok    student01 creates a hostNetwork pod                        denied
  ok    student01 creates an ordinary pod                          admitted
  ok    student01 relabels student01 to privileged                 forbidden
  ok    mentor: pod security enforce label                         baseline
  ok    student01: pod security enforce label                      baseline
  ok    student02: pod security enforce label                      baseline
  ok    student03: pod security enforce label                      baseline
```

The checks can fail. After `kubectl label ns student01 pod-security.kubernetes.io/enforce-` the first three lines print `FAIL ... admitted (expected denied)`, the label line prints `FAIL ... none (expected baseline)`, and the script exits 1. `kubectl apply -k platform/` restores the label.

## Policies

### Why ValidatingPolicy and MutatingPolicy

Both policies use the CEL-based types `ValidatingPolicy` and `MutatingPolicy` (`policies.kyverno.io/v1`) instead of `ClusterPolicy`. `ClusterPolicy` is deprecated in Kyverno 1.19 and removed in 1.20, so a new policy written as `ClusterPolicy` would have to be rewritten at the next upgrade.

### require-ro-rootfs

Task 2: a policy that validates a readonly root filesystem, in audit mode.

- `validationActions: [Audit]`: a pod with a writable root filesystem is admitted, and the result is recorded in a PolicyReport. Enforcement would be `[Deny]`; the task asks for Audit.
- It checks `containers`, `initContainers` and `ephemeralContainers`. Every one of them must set `securityContext.readOnlyRootFilesystem: true`. A container that does not set the field counts as writable.
- The failure message names the writable containers.
- `kube-system`, `kube-public`, `kube-node-lease`, `kyverno` and `local-path-storage` are excluded, so the report shows workload findings and no platform noise.
- Background scanning is on, so pods that already run are reported too.
- Kyverno's autogen is left on: the policy also reports Deployments and the other pod controllers, not only Pods.

To read the findings: `kubectl get policyreport -A`.

### person-label

Task 3: pods get the label `person: student` in the student namespaces, `person: mentor` in the mentor's namespace, and no `person` label anywhere else.

- The role is taken from the namespace label `k8s-prod.io/role` (`student` or `mentor`), not from a list of names. Namespaces are cluster-scoped, so only the cluster admin can set that label. A student with `edit` in their own namespace cannot change the role of that namespace.
- The policy matches Pods on CREATE and UPDATE. A `person` label that is missing or wrong is set to the namespace's value. In every namespace without a student or mentor role, an existing `person` label is removed. As a result the label cannot be added or changed by hand: a manifest that sets it ends up with the namespace's value (or with no label), and `kubectl label` on a running pod is accepted and then reverted by the mutation.
- Autogen is turned off (`autogen.podControllers.controllers: []`). The controller rules Kyverno generated reused the Pod patch paths, so they would have relabelled the Deployments themselves. Pods are mutated at creation whichever controller created them, so nothing is lost.
- Existing pods are not touched when the policy is installed. They carry their old labels until they are recreated.

## How to verify

One command, from the repository root, after `make up`:

```
make verify
```

It runs the three steps below and stops at the first failing step. They can be run on their own:

```
kyverno test tests/kyverno
export KUBECONFIG=$PWD/out/admin.kubeconfig
scripts/verify-rbac.sh
scripts/verify-policies.sh
```

`KUBECONFIG` must point at the admin kubeconfig for `verify-rbac.sh`: it uses it to clean up its probe objects and to list ClusterRoleBindings. Each script exits non-zero if any answer differs from the expected one.

The output below was captured from a real run.

### 1. Unit tests

`kyverno test tests/kyverno` checks both policies offline, without a cluster:

- `person-label`: pods in `student01`, `student02`, `mentor` and `default`, with no labels, with other labels, with a wrong `person` value, with an empty one. Each patched result is compared with the expected manifest.
- `require-ro-rootfs`: a passing pod, a pod with one writable container, a pod with a writable init container, a failing Deployment, and a pod in `kube-system` that must be excluded.

```
Test Summary: 13 tests passed and 0 tests failed
```

### 2. RBAC matrix

`scripts/verify-rbac.sh` uses each person's own kubeconfig (real client certificates, not `--as`). For every person and every namespace in `mentor`, `student01`, `student02`, `student03`, `default`, `kube-system` it asks four questions: get pods, list secrets, create deployments, delete pods. It then asks the cluster-wide and self-escalation questions. After that it makes real API calls, runs the pod security checks described above, and finally lists ClusterRoleBindings.

There are 138 checks. All of them passed. The block for student02, the person with the mixed grants:

```
== student02 (["students","system:authenticated"])
  ok    mentor: get pods                                           no
  ok    mentor: list secrets                                       no
  ok    mentor: create deployments                                 no
  ok    mentor: delete pods                                        no
  ok    student01: get pods                                        yes
  ok    student01: list secrets                                    no
  ok    student01: create deployments                              no
  ok    student01: delete pods                                     no
  ok    student02: get pods                                        yes
  ok    student02: list secrets                                    yes
  ok    student02: create deployments                              yes
  ok    student02: delete pods                                     yes
  ok    student03: get pods                                        no
  ok    student03: list secrets                                    no
  ok    student03: create deployments                              no
  ok    student03: delete pods                                     no
  ok    default: get pods                                          yes
  ok    default: list secrets                                      no
  ok    default: create deployments                                no
  ok    default: delete pods                                       no
  ok    kube-system: get pods                                      no
  ok    kube-system: list secrets                                  no
  ok    kube-system: create deployments                            no
  ok    kube-system: delete pods                                   no
  ok    cluster: * * (cluster-admin)                               no
  ok    cluster: create clusterrolebindings                        no
  ok    cluster: list namespaces                                   no
  ok    cluster: list nodes                                        no
  ok    student02: create rolebindings (no self-escalation)        no
  ok    student02: impersonate users                               no
```

The real API calls, the pod security checks and the final lines:

```
== real API calls
  ok    student01 creates a ConfigMap in student01                 ok
  ok    student01 creates a ConfigMap in student03                 forbidden
  ok    student02 lists pods in student01                          ok
  ok    student02 creates a ConfigMap in student01                 forbidden
  ok    student02 lists pods in default                            ok
  ok    mentor creates a ConfigMap in student02                    ok
  ok    mentor lists pods in kube-system                           forbidden
  ok    student03 lists all namespaces                             forbidden
== pod security
  ok    student01 creates a privileged pod                         denied
  ok    student01 creates a hostPath / pod on the control plane    denied
  ok    student01 creates a hostNetwork pod                        denied
  ok    student01 creates an ordinary pod                          admitted
  ok    student01 relabels student01 to privileged                 forbidden
  ok    mentor: pod security enforce label                         baseline
  ok    student01: pod security enforce label                      baseline
  ok    student02: pod security enforce label                      baseline
  ok    student03: pod security enforce label                      baseline
== no cluster-wide binding names a person
  ok    ClusterRoleBindings for mentor/students/groups             
RBAC: all checks passed
```

### 3. Policy behaviour on the live cluster

`scripts/verify-policies.sh` creates throwaway pods with the admin kubeconfig, reads back the labels and the PolicyReport, and deletes the pods on exit:

```
== person-label
  ok    student01: new pod                                         student
  ok    mentor: new pod                                            mentor
  ok    default: manifest sets person=student                      none
  ok    default: kubectl label person=x is accepted                ok
  ok    default: person label is gone after kubectl label          none
  ok    student02: manifest sets person=mentor                     student
== require-ro-rootfs (Audit)
  ok    student03: writable rootfs pod is admitted                 admitted
  ok    student03: read-only rootfs pod is admitted                admitted
  ok    student03: writable rootfs pod in the report               fail
  ok    student03: read-only rootfs pod in the report              pass
Policies: all checks passed
```

Read the `person-label` lines this way: a pod in `student01` and one in `mentor` get their label; a manifest in `default` that sets `person=student` ends up with no label; a manifest in `student02` that sets `person=mentor` ends up with `student`; and `kubectl label ... person=x` in `default` is accepted but the label is gone afterwards. Both rootfs pods are admitted, which is what Audit means, and only the writable one is reported as `fail`.

## A pitfall: asking `can-i` about cluster-scoped resources

`kubectl auth can-i list namespaces`, asked inside a namespace, answers `yes` for a person with `view` or `edit` there. The question is answered for that namespace's own Namespace object, which these roles may read. It says nothing about listing all namespaces.

Cluster-scoped questions must be asked with `--all-namespaces`, and the real call settles it:

```
kubectl --kubeconfig out/kubeconfigs/student03.kubeconfig auth can-i list namespaces                    # yes: own Namespace object
kubectl --kubeconfig out/kubeconfigs/student03.kubeconfig auth can-i list namespaces --all-namespaces   # no
kubectl --kubeconfig out/kubeconfigs/student03.kubeconfig get namespaces                                 # Forbidden
```

`scripts/verify-rbac.sh` asks its cluster-scoped questions this way, and also makes the real `get namespaces` call.
