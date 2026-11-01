# Module 04: Istio service mesh

This page is for the reviewer. It lists what the repository builds for Module 04, the decisions behind it, and the commands that prove each claim.

## What is built

| Task | What exists | Where |
|---|---|---|
| 1. Istio service mesh in sidecar mode | Istio 1.31.3 from the three official Helm charts (`base`, `cni`, `istiod`), installed by Flux as HelmReleases in `istio-system`. Sidecar injection uses the Istio CNI plugin, so injected pods need no `NET_ADMIN` init container | `infrastructure/istio/` |
| 2. A Kyverno policy so that pods with `person: student` run with the Istio sidecar | MutatingPolicy `istio-sidecar-for-students`: it sets `sidecar.istio.io/inject: "true"` on student pods and the Istio injector adds the `istio-proxy` container. Kyverno turns the policy into a native MutatingAdmissionPolicy (see [the ordering trap](#the-ordering-trap)) | `charts/kyverno-policies/templates/istio-sidecar-for-students.yaml` |

Everything reaches the cluster through Git, like the earlier modules. `make verify` has a new step, `scripts/verify-mesh.sh`, and `make up` waits for the three new HelmReleases.

## Versions

| Component | Version | Pinned in |
|---|---|---|
| Istio (charts `base`, `cni`, `istiod`) | 1.31.3 | `infrastructure/istio/repositories.yaml` (`ref.tag`) |
| Istio images | `docker.io/istio/{pilot,install-cni,proxyv2}:1.31.3` | chart default (`global.hub`, `global.tag`) |
| Kyverno | 1.19.2 (Helm chart 3.9.2), unchanged | `infrastructure/kyverno/release.yaml` |
| Kubernetes | v1.37.0 (kind). MutatingAdmissionPolicy is stable since v1.36 | `cluster/kind.yaml` |

Local tools: istioctl 1.31.3 (used by `verify-mesh.sh`), flux 2.10.0, helm v4.1.3, kubeconform 0.8.0, kyverno CLI 1.19.2.

**Why the charts come from ghcr.io.** Istio 1.31.3 is published as OCI charts at `oci://ghcr.io/istio/release/charts/{base,cni,istiod}`. The older locations stop at 1.30: `gcr.io/istio-release/charts/istiod:1.31.3` does not exist (1.30.0 does), and the classic Helm repository `https://istio-release.storage.googleapis.com/charts` lists 1.30.7 as the last release and only 1.31.0 pre-releases. Both were checked while building this module.

## Layout

```
infrastructure/istio/
  namespace.yaml      istio-system, Pod Security enforce=privileged
  repositories.yaml   three OCIRepository objects, tag 1.31.3
  releases.yaml       HelmReleases istio-base, istio-cni, istiod
charts/kyverno-policies/templates/istio-sidecar-for-students.yaml
tests/kyverno/istio-sidecar-for-students/
scripts/verify-mesh.sh
```

The order of events on a new cluster:

1. The `infrastructure` Kustomization applies `infrastructure/`: Kyverno as before, and now `infrastructure/istio/`.
2. The HelmReleases are chained with `dependsOn`: `istio-base` (CRDs), then `istio-cni`, then `istiod`. The charts are not fetched with a HelmRepository. Each chart is an `OCIRepository` and the HelmRelease uses `chartRef`, so Flux pulls the chart by tag from the registry. `layerSelector` with the Helm chart media type is what lets a HelmRelease read a chart from an OCIRepository.
3. `infrastructure` has `wait: true`, so it is Ready only when Kyverno and all three Istio releases are Ready.
4. `platform` depends on `infrastructure`, so the policy releases come after istiod exists. The `kyverno-policies` HelmRelease also lists `istiod` in its own `dependsOn`, so the order holds even if the Kustomizations are reorganised.

## Sidecar mode with the Istio CNI plugin

In sidecar mode every pod gets an Envoy proxy next to the application. Traffic is redirected into the proxy with iptables rules inside the pod's network namespace. Without the CNI plugin an init container (`istio-init`) sets those rules, and it needs `NET_ADMIN` and `NET_RAW` and runs as root. Pod Security `baseline` rejects added capabilities, so that init container would be refused in the student namespaces.

With the Istio CNI plugin the rules are set up on the node, when the pod's network is created. The injected pod gets `istio-validation` instead of `istio-init`. It only checks that the redirection is in place, drops all capabilities, runs as non-root with a read-only root filesystem, and so does `istio-proxy`. The student namespaces stay at `baseline` and no exception is needed there.

The price is the node agent. `istio-cni-node` is a DaemonSet that runs as root, mounts host directories (`/opt/cni/bin`, `/etc/cni/net.d`) and adds capabilities (`NET_ADMIN`, `NET_RAW`, `SYS_ADMIN` and others), so it cannot run under `baseline`. For that reason `istio-system` carries `pod-security.kubernetes.io/enforce: privileged`. No person has any right in that namespace (see Module 02), so the relaxation does not reach the students.

Settings, all in `infrastructure/istio/releases.yaml`:

| Release | Value | Why |
|---|---|---|
| `istiod` | `pilot.cni.enabled: true` | injected pods get `istio-validation`, not `istio-init` |
| `istiod` | `pilot.autoscaleEnabled: false`, `pilot.replicaCount: 1` | one control plane replica on the lab, no HPA |
| `istiod` | `pilot.resources.requests`: 100m, 256Mi | the chart default is 500m and 2Gi |
| `istiod` | `global.proxy.resources`: requests 10m and 40Mi, limits 500m and 256Mi | what every sidecar gets; the chart default is 100m and 128Mi requests with a 1Gi limit |
| `istio-cni` | `resources.requests`: 20m, 64Mi | the chart default is 100m and 100Mi on each of the four nodes |

The `istio-cni` defaults already fit kind: chained mode, `/opt/cni/bin`, `/etc/cni/net.d`. kind's own CNI (`kindnet`) stays the primary plugin and Istio's plugin is appended to its chain.

On Kubernetes 1.37 Istio 1.31 injects the proxy as a native sidecar: `istio-proxy` is an init container with `restartPolicy: Always`, next to `istio-validation`. It is not in `spec.containers`. `kubectl get pod` shows the pod as `2/2` because ready native sidecars count, and logs are read with `kubectl logs <pod> -c istio-proxy`.

Measured on the lab (`crictl stats`, working set): istiod 54 MiB, the four CNI agents 12 to 31 MiB each (122 MiB for all of `istio-system`), and about 27 MiB per sidecar. The cluster-level memory (`docker stats` of the kind nodes) rose by about 1 GiB while Istio was installed and did not fall after it was removed, so it is mostly API server heap and cached images and not the steady-state cost of Istio.

## The policy

`istio-sidecar-for-students` is a `MutatingPolicy` (`policies.kyverno.io/v1`), like `person-label`.

- It matches Pods on CREATE and reads the role from the namespace label `k8s-prod.io/role`. In a namespace with the role `student` it sets `sidecar.istio.io/inject: "true"`. These are exactly the pods with `person: student`: `person-label` sets that label in the student namespaces and removes it everywhere else, so a pod cannot become a student pod by labelling it by hand. Namespaces are cluster-scoped, so only the cluster admin can change the role.
- The label is set to `true` even if the manifest says `false`. A student cannot opt out by writing `sidecar.istio.io/inject: "false"` (tested, see below).
- Mentor and `default` pods are not touched, including a `default` pod that sets `person: student` in its manifest.
- The Istio injector `object.sidecar-injector.istio.io` selects pods with the label `sidecar.istio.io/inject: "true"`. It then adds `istio-validation` and `istio-proxy`. This is the part that makes the pod "run with the istio-sidecar container".
- Autogen for pod controllers is off, like in `person-label`: only Pods carry the label, and the controllers are not relabelled. Pods created by a Deployment pass through the same admission, so they get the label too.
- Existing pods are not touched when the policy is installed. A pod without a sidecar gets one when it is recreated, for example with `kubectl rollout restart`.

### The ordering trap

The first version of the policy was a plain webhook mutation, and it did not work. A pod created in `student01` came out with `person: student` and `sidecar.istio.io/inject: "true"` and **no** `istio-proxy`.

The cause is the order of the admission webhooks. The API server calls mutating webhooks by the name of their configuration: `istio-sidecar-injector` comes before `kyverno-resource-mutating-webhook-cfg`. When the injector looks at the pod, the label does not exist yet, its `objectSelector` does not match and it skips the pod. Kyverno adds the label afterwards, and nothing sends the pod back to the injector.

Setting the injector's `reinvocationPolicy` to `IfNeeded` does not help, and was tried: the pod still had no sidecar. The Kubernetes documentation says an `IfNeeded` webhook "may be called again as part of the admission evaluation if the object being admitted is modified by other admission plugins after the initial webhook call". The injector never had an initial call, so there was nothing to repeat. The setting is therefore not part of the install.

The fix is to make the label appear before any webhook runs. Kyverno can generate a native Kubernetes `MutatingAdmissionPolicy` from a `MutatingPolicy` (`spec.autogen.mutatingAdmissionPolicy.enabled: true`). The API server evaluates that kind of policy itself, before the admission webhooks, so the label is already on the pod when the injector looks. Kyverno creates `mutatingadmissionpolicy/mpol-istio-sidecar-for-students` and its binding and removes them with the policy. The behaviour was observed on this cluster: with the generated policy the bare Pod and the Deployment pods are injected in the same admission.

Two consequences:

- `person-label` is a webhook mutation, so it has not run yet when this policy is evaluated and its label is not visible. The policy therefore reads the namespace role, which is also where `person-label` takes its value from, and not the `person` label.
- The generated policy has `failurePolicy: Fail`, like the Kyverno policy it comes from, and matches Pods in every namespace. An error in its expressions would block pod creation cluster-wide. The expressions use optional field access only, and the unit tests below cover the empty and missing label cases.

## How to verify

One command, from the repository root, after `make up`:

```
make verify
```

It now has four steps (unit tests, RBAC, policies, mesh) and the Flux check. The mesh step on its own:

```
export KUBECONFIG=$PWD/out/admin.kubeconfig
scripts/verify-mesh.sh
```

### 1. Local tests (before any deploy)

```
make render
kyverno test tests/kyverno/istio-sidecar-for-students
kyverno test tests/kyverno
make lint
```

`kyverno test tests/kyverno/istio-sidecar-for-students` runs nine cases on what the chart renders. Each patched result is compared with the expected manifest:

| Case | Expected |
|---|---|
| `student-nolabels`: pod in `student01` without labels | label added (the labels map is created) |
| `student-labels`: pod in `student01` with other labels | label added |
| `student-optout`: pod in `student02` with `inject: "false"` | changed to `"true"` |
| `student-already`: pod in `student01` with `inject: "true"` | unchanged |
| `student-wrong-person`: pod in `student02` with `person: mentor` | label added (the namespace role decides) |
| `person-in-default`: pod in `default` with `person: student` set by hand | unchanged |
| `mentor-pod`: pod in `mentor` | unchanged |
| `mentor-optout`: pod in `mentor` with `inject: "false"` | unchanged |
| `default-pod`: pod in `default` | unchanged |

`kyverno test tests/kyverno` runs all 22 tests (13 from Module 02 and 9 new). `make lint` runs helm lint and kubeconform on the charts and on `infrastructure/`, which now includes the Istio manifests.

### 2. The mesh on the cluster

`scripts/verify-mesh.sh` creates throwaway workloads (a bare Pod and a one-replica Deployment in `student01`, both with student01's own kubeconfig, a pod in `mentor` and one in `default`) and removes them on exit. It checks:

- istiod is Ready, `istio-cni-node` is Ready on every node, `istio-system` is `privileged`, the policy is Ready and the native MutatingAdmissionPolicy exists.
- Both student pods are admitted under Pod Security `baseline` and have the init containers `istio-validation` and `istio-proxy` (native sidecar); `istio-proxy` is ready; the pod's own container list is only `app`.
- A student pod whose manifest says `sidecar.istio.io/inject: "false"` still gets the sidecar.
- The mentor and `default` pods have no sidecar and no injection label. This includes a `default` pod that sets `person: student` in its manifest: `person-label` removes the label and the policy does not look at it.
- The sidecar runs the same version as istiod, has the 10m and 40Mi requests, and there is no `istio-init`.
- `istioctl proxy-status` lists the student pods and does not list the mentor and `default` pods.
- With the sidecar present, a student pod whose app is read-only passes `require-ro-rootfs`, and a pod with a writable app is reported for the `app` container only.

The checks can fail. With the policy deleted, the script reports `FAIL` lines for the missing sidecar, the missing label and the pods absent from `proxy-status`, and exits 1.

Useful commands to look at the mesh by hand:

```
kubectl get pods -n istio-system
istioctl proxy-status
kubectl get mutatingpolicy,mutatingadmissionpolicy
kubectl get pod <pod> -n student01 -o jsonpath='{range .spec.initContainers[*]}{.name}{" "}{.restartPolicy}{"\n"}{end}'
kubectl get mutatingwebhookconfiguration istio-sidecar-injector -o jsonpath='{.webhooks[*].name}'
```

## Things to know

- **Fail closed.** The injector webhook has `failurePolicy: Fail`. While istiod is not ready, creating a pod with `sidecar.istio.io/inject: "true"` is rejected, so a student pod never runs without its sidecar. There is one istiod replica on the lab, so an istiod restart briefly blocks new student pods.
- **Pods that already run** keep their old shape until they are recreated.
- **A hand-set `person: student` outside the student namespaces does nothing.** `person-label` removes the label, and the sidecar policy keys on the namespace role only, so such a pod gets no sidecar. The reverse also holds: a pod in a student namespace gets the sidecar whatever `person` value its manifest carries.
- **Uninstall leaves the CRDs.** Istio's CRDs carry `helm.sh/resource-policy: keep`. Deleting the Istio HelmReleases removes the control plane and keeps the 15 CRDs, which is the safe default because deleting a CRD deletes every custom resource of that kind.
- **`istio-system` is excluded from `require-ro-rootfs`.** The CNI agent's `install-cni` container writes to host directories and is reported as writable, so platform pods would show up as findings. The namespace is added to `excludedNamespaces` in `charts/kyverno-policies/values.yaml`. Pods in the student namespaces are still checked as a whole: `istio-validation` and `istio-proxy` are read-only, so only a writable app container is reported.
- **Not in scope.** No mTLS policy, gateway or traffic rule is configured. The mesh is installed and the student pods are enrolled; `PeerAuthentication` and the routing resources are not part of the homework.

## Changes to earlier modules

| File | Change |
|---|---|
| `infrastructure/kustomization.yaml` | adds `istio` |
| `releases/kyverno-policies.yaml` | `dependsOn` also lists `istiod` |
| `charts/kyverno-policies/values.yaml` | `istio-system` added to `excludedNamespaces` (the Module 03 table lists the older default) |
| `charts/kyverno-policies/Chart.yaml` | description mentions the new policy |
| `scripts/wait-flux.sh`, `scripts/verify-flux.sh` | the three Istio HelmReleases are waited for and checked |
| `Makefile` | `verify` runs `scripts/verify-mesh.sh` |

## Live run

The lab was rebuilt from zero with `make down && make up` (exit 0): the cluster follows `refs/heads/module-04` at `4a36dbc`, everything came from Git (Istio 1.31.3 charts from `ghcr.io`), and the log holds 197 `ok` lines and no `FAIL`.

### make up

```
Flux: everything is Ready
Test Summary: 22 tests passed and 0 tests failed
RBAC: all checks passed
Policies: all checks passed
Mesh: all checks passed
Flux: all checks passed
```

### scripts/verify-mesh.sh

```
== control plane
  ok    istiod: ready replicas                                         1
  ok    istio-cni-node: ready on every node                            4/4
  ok    istio-system: pod security enforce label                       privileged
  ok    policy istio-sidecar-for-students is Ready                     true
  ok    native MutatingAdmissionPolicy was generated from it           mpol-istio-sidecar-for-students
== sidecar injection
  ok    student01: bare pod is admitted (Pod Security baseline)        admitted
  ok    student01: deployment is admitted                              admitted
  ok    student01: pod with inject=false in the manifest is admitted   admitted
  ok    mentor: pod is admitted                                        admitted
  ok    default: pod is admitted                                       admitted
  ok    default: pod with person=student in the manifest is admitted   admitted
  ok    student01: bare pod has the sidecar                            istio-validation,istio-proxy(sidecar)
  ok    student01: deployment pod has the sidecar                      istio-validation,istio-proxy(sidecar)
  ok    student01: inject=false in the manifest is overridden          istio-validation,istio-proxy(sidecar)
  ok    student01: bare pod has the label sidecar.istio.io/inject      true
  ok    student01: istio-proxy of the bare pod is ready                true
  ok    student01: istio-proxy of the deployment pod is ready          true
  ok    student01: the pod's own containers are only the app           app
  ok    mentor: pod has no sidecar                                     none
  ok    default: pod has no sidecar                                    none
  ok    default: pod with person=student in the manifest has no sidecar none
  ok    default: that pod has no person label either (person-label removed it) none
  ok    mentor: pod has no label sidecar.istio.io/inject               none
  ok    default: person=student pod has no label sidecar.istio.io/inject none
== sidecar settings
  ok    istio-proxy runs the version of istiod                         1.31.3
  ok    istio-proxy requests (global.proxy.resources)                  10m/40Mi
  ok    istio-validation replaces istio-init (no NET_ADMIN init container) none
== mesh
  ok    istioctl proxy-status lists the bare pod                       listed
  ok    istioctl proxy-status lists the deployment pod                 listed
  ok    istioctl proxy-status lists the pod with inject=false in the manifest listed
  ok    istioctl proxy-status does not list the mentor pod             absent
  ok    istioctl proxy-status does not list the default pod            absent
  ok    istioctl proxy-status does not list the default person=student pod absent
== require-ro-rootfs with the sidecar
  ok    student01: bare pod with a read-only app passes, sidecar included pass success
  ok    student01: deployment pod reports only the app container       fail readOnlyRootFilesystem must be true; writable: app
Mesh: all checks passed
```

### Demo after the run

```
$ flux get helmreleases -A
NAMESPACE    NAME              REVISION             SUSPENDED  READY  MESSAGE
flux-system  istio-base        1.31.3+2c9822f5a4ce  False      True   Helm install succeeded for release istio-system/istio-base.v1 with chart base@1.31.3+2c9822f5a4ce
flux-system  istio-cni         1.31.3+65bc2f95324d  False      True   Helm install succeeded for release istio-system/istio-cni.v1 with chart cni@1.31.3+65bc2f95324d
flux-system  istiod            1.31.3+c22f231186a1  False      True   Helm install succeeded for release istio-system/istiod.v1 with chart istiod@1.31.3+c22f231186a1
flux-system  kyverno           3.9.2                False      True   Helm install succeeded for release kyverno/kyverno.v1 with chart kyverno@3.9.2
flux-system  kyverno-policies  0.1.0+4a36dbc18238   False      True   Helm install succeeded for release flux-system/kyverno-policies.v1 with chart kyverno-policies@0.1.0+4a36dbc18238
flux-system  tenants           0.1.0+4a36dbc18238   False      True   Helm install succeeded for release flux-system/tenants.v1 with chart tenants@0.1.0+4a36dbc18238

$ kubectl get pods -n istio-system
NAME                      READY   STATUS    RESTARTS   AGE
istio-cni-node-hzxtn      1/1     Running   0          3m51s
istio-cni-node-jnpft      1/1     Running   0          3m51s
istio-cni-node-stlkh      1/1     Running   0          3m51s
istio-cni-node-tvdfv      1/1     Running   0          3m51s
istiod-5c6d4d77d4-dbz2g   1/1     Running   0          2m51s

$ kubectl get mutatingadmissionpolicy
NAME                              MUTATIONS   PARAMKIND   AGE
mpol-istio-sidecar-for-students   1           <unset>     2m23s

$ kubectl get pod live-demo -n student01 -o custom-columns=NAME:.metadata.name,PERSON:.metadata.labels.person,INJECT:.metadata.labels.sidecar\.istio\.io/inject,INIT:.spec.initContainers[*].name,CONTAINERS:.spec.containers[*].name,READY:.status.containerStatuses[*].ready
NAME        PERSON    INJECT   INIT                           CONTAINERS
live-demo   student   true     istio-validation,istio-proxy   live-demo

$ kubectl get pod live-demo -n mentor (same columns)
NAME        PERSON   INJECT   INIT     CONTAINERS
live-demo   mentor   <none>   <none>   live-demo

$ istioctl proxy-status
NAME                    CLUSTER        ISTIOD                      VERSION     SUBSCRIBED TYPES
live-demo.student01     Kubernetes     istiod-5c6d4d77d4-dbz2g     1.31.3      4 (CDS,LDS,EDS,RDS)
```

The student pod has the native sidecar in `initContainers` and is the only proxy `istiod` knows; the mentor pod is untouched.
