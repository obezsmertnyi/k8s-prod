#!/usr/bin/env bash
# Checks the Istio mesh on the live cluster with throwaway workloads: the control plane is Ready, pods of the student
# namespaces get the sidecar (a bare Pod and a Deployment, created with student01's own kubeconfig), mentor and default
# pods do not (not even a default pod that sets person=student by hand), and the sidecar passes Pod Security baseline
# and require-ro-rootfs. The validating policy require-istio-sidecar-for-students must be Ready and must accept a
# student pod after the injection (server-side dry-run). It has no live deny check: every student pod without a sidecar
# needs a broken component (see docs/module-04.md), so the deny cases are covered by the Kyverno CLI tests.
# Exits non-zero if any answer differs from the expected one. Test workloads are removed on exit.
set -uo pipefail

export KUBECONFIG="$PWD/out/admin.kubeconfig"
dir=out/kubeconfigs
namespaces=(mentor student01 default)
mark=verify-mesh   # label on every test workload, used for cleanup
wait=240s          # the first injection pulls the proxy image on each node
fail=0

command -v istioctl >/dev/null || { echo "istioctl is not installed" >&2; exit 1; }

cleanup() {
  for ns in "${namespaces[@]}"; do
    kubectl delete deployments,pods -n "$ns" -l "$mark=run" --now --ignore-not-found >/dev/null 2>&1
  done
}
trap cleanup EXIT
trap 'exit 1' INT TERM

check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then printf '  ok    %-62s %s\n' "$1" "$3"
  else printf '  FAIL  %-62s %s (expected %s)\n' "$1" "$3" "$2"; fail=1; fi
}

# create <kubeconfig user, or admin> <namespace> <name> <app readOnlyRootFilesystem> [pod labels as JSON] [apply flag]
# Applies a Pod, or a one-replica Deployment when the name ends in -deploy. Prints admitted or denied.
# The flag is passed to kubectl apply, for example --dry-run=server: the full admission chain runs, nothing is stored.
create() {
  local kc=$KUBECONFIG; [ "$1" != admin ] && kc=$dir/$1.kubeconfig
  local labels=${5:-}; [ -z "$labels" ] && labels='{}'
  local flag=${6:-}
  local pod out rc
  pod=$(jq -n --arg n "$3" --arg m "$mark" --argjson ro "$4" --argjson l "$labels" '{
      metadata: {labels: ($l + {($m): "run", app: $n})},
      spec: {containers: [{name: "app", image: "busybox:1.37", command: ["sleep", "3600"],
        securityContext: {readOnlyRootFilesystem: $ro}, resources: {requests: {cpu: "10m", memory: "16Mi"}}}]}}')
  if [[ $3 == *-deploy ]]; then
    out=$(jq -n --arg n "$3" --arg m "$mark" --argjson p "$pod" '{apiVersion: "apps/v1", kind: "Deployment",
        metadata: {name: $n, labels: {($m): "run"}}, spec: {replicas: 1, selector: {matchLabels: {app: $n}},
        template: $p}}' | kubectl --kubeconfig "$kc" apply ${flag:+"$flag"} -n "$2" -f - 2>&1); rc=$?
  else
    out=$(jq -n --arg n "$3" --argjson p "$pod" '{apiVersion: "v1", kind: "Pod", metadata: ($p.metadata + {name: $n}),
        spec: $p.spec}' | kubectl --kubeconfig "$kc" apply ${flag:+"$flag"} -n "$2" -f - 2>&1); rc=$?
  fi
  if [ "$rc" -eq 0 ]; then echo admitted
  elif grep -q 'violates PodSecurity' <<<"$out"; then echo denied
  else echo "error: $out"; fi
}

podof() { # podof <namespace> <name> -> the Pod itself, or the first Pod of the Deployment of that name
  if [[ $2 == *-deploy ]]; then
    kubectl get pods -n "$1" -l "app=$2" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
  else echo "$2"; fi
}

shape() { # shape <namespace> <pod> -> init containers; a native sidecar is marked (sidecar); none without init containers
  kubectl get pod "$2" -n "$1" -o json 2>/dev/null | jq -r '[.spec.initContainers[]? |
    .name + (if .restartPolicy == "Always" then "(sidecar)" else "" end)] | join(",") | if . == "" then "none" else . end'
}

field() { # field <namespace> <pod> <jq filter>
  kubectl get pod "$2" -n "$1" -o json 2>/dev/null | jq -r "$3"
}

report() { # report <namespace> <pod> -> require-ro-rootfs result and message, waits up to 60 s for the report
  local uid r=none
  uid=$(kubectl get pod "$2" -n "$1" -o jsonpath='{.metadata.uid}' 2>/dev/null)
  for _ in $(seq 1 30); do
    r=$(kubectl get policyreport "$uid" -n "$1" -o json 2>/dev/null | jq -r '[.results[]? |
      select(.policy == "require-ro-rootfs") | .result + " " + (.message // "")] | first // "none"')
    [ "${r:-none}" != none ] && break
    sleep 2
  done
  echo "${r:-none}"
}

cleanup   # leftovers from an interrupted run

echo "== control plane"
want=$(kubectl get daemonset istio-cni-node -n istio-system -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)
check "istiod: ready replicas" 1 "$(kubectl get deployment istiod -n istio-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
check "istio-cni-node: ready on every node" "$want/$want" \
  "$(kubectl get daemonset istio-cni-node -n istio-system -o jsonpath='{.status.numberReady}' 2>/dev/null)/$want"
check "istio-system: pod security enforce label" privileged \
  "$(kubectl get namespace istio-system -o json | jq -r '.metadata.labels["pod-security.kubernetes.io/enforce"] // "none"')"
check "policy istio-sidecar-for-students is Ready" true \
  "$(kubectl get mutatingpolicy istio-sidecar-for-students -o jsonpath='{.status.conditionStatus.ready}' 2>/dev/null)"
check "native MutatingAdmissionPolicy was generated from it" mpol-istio-sidecar-for-students \
  "$(kubectl get mutatingadmissionpolicy mpol-istio-sidecar-for-students -o jsonpath='{.metadata.name}' 2>/dev/null)"
check "policy require-istio-sidecar-for-students is Ready" true \
  "$(kubectl get validatingpolicies.policies.kyverno.io require-istio-sidecar-for-students -o jsonpath='{.status.conditionStatus.ready}' 2>/dev/null)"

echo "== sidecar injection"
check "student01: bare pod is admitted (Pod Security baseline)" admitted "$(create student01 student01 vm-bare true)"
check "student01: deployment is admitted" admitted "$(create student01 student01 vm-deploy false)"
check "student01: pod with inject=false in the manifest is admitted" admitted \
  "$(create student01 student01 vm-optout false '{"sidecar.istio.io/inject": "false"}')"
check "mentor: pod is admitted" admitted "$(create mentor mentor vm-mentor false)"
check "default: pod is admitted" admitted "$(create admin default vm-default false)"
check "default: pod with person=student in the manifest is admitted" admitted \
  "$(create admin default vm-person false '{"person": "student"}')"
# The validating policy runs after the injection, so a student pod, which gets its sidecar first, is accepted.
check "student01: dry-run of a person=student pod is accepted" admitted \
  "$(create student01 student01 vm-dry false '{"person": "student"}' --dry-run=server)"
kubectl wait --for=condition=Ready pod/vm-bare pod/vm-optout -n student01 --timeout="$wait" >/dev/null 2>&1
kubectl rollout status deployment/vm-deploy -n student01 --timeout="$wait" >/dev/null 2>&1
kubectl wait --for=condition=Ready pod/vm-mentor -n mentor --timeout="$wait" >/dev/null 2>&1
kubectl wait --for=condition=Ready pod/vm-default pod/vm-person -n default --timeout="$wait" >/dev/null 2>&1
deploypod=$(podof student01 vm-deploy)

sidecar="istio-validation,istio-proxy(sidecar)"
check "student01: bare pod has the sidecar" "$sidecar" "$(shape student01 vm-bare)"
check "student01: deployment pod has the sidecar" "$sidecar" "$(shape student01 "$deploypod")"
check "student01: inject=false in the manifest is overridden" "$sidecar" "$(shape student01 vm-optout)"
check "student01: bare pod has the label sidecar.istio.io/inject" true \
  "$(field student01 vm-bare '.metadata.labels["sidecar.istio.io/inject"] // "none"')"
check "student01: istio-proxy of the bare pod is ready" true \
  "$(field student01 vm-bare '[.status.initContainerStatuses[]? | select(.name == "istio-proxy") | .ready] | first // false')"
check "student01: istio-proxy of the deployment pod is ready" true \
  "$(field student01 "$deploypod" '[.status.initContainerStatuses[]? | select(.name == "istio-proxy") | .ready] | first // false')"
check "student01: the pod's own containers are only the app" app \
  "$(field student01 vm-bare '[.spec.containers[].name] | join(",")')"
check "mentor: pod has no sidecar" none "$(shape mentor vm-mentor)"
check "default: pod has no sidecar" none "$(shape default vm-default)"
check "default: pod with person=student in the manifest has no sidecar" none "$(shape default vm-person)"
check "default: that pod has no person label either (person-label removed it)" none \
  "$(field default vm-person '.metadata.labels.person // "none"')"
check "mentor: pod has no label sidecar.istio.io/inject" none \
  "$(field mentor vm-mentor '.metadata.labels["sidecar.istio.io/inject"] // "none"')"
check "default: person=student pod has no label sidecar.istio.io/inject" none \
  "$(field default vm-person '.metadata.labels["sidecar.istio.io/inject"] // "none"')"

echo "== sidecar settings"
version() { sed 's/.*://'; }
check "istio-proxy runs the version of istiod" \
  "$(kubectl get deployment istiod -n istio-system -o jsonpath='{.spec.template.spec.containers[0].image}' | version)" \
  "$(field student01 vm-bare '[.spec.initContainers[]? | select(.name == "istio-proxy") | .image] | first // ""' | version)"
check "istio-proxy requests (global.proxy.resources)" "10m/40Mi" \
  "$(field student01 vm-bare '[.spec.initContainers[]? | select(.name == "istio-proxy") | .resources.requests | "\(.cpu)/\(.memory)"] | first // ""')"
check "istio-validation replaces istio-init (no NET_ADMIN init container)" none \
  "$(field student01 vm-bare '[.spec.initContainers[]? | select(.name == "istio-init") | .name] | first // "none"')"

echo "== mesh"
meshed() { istioctl proxy-status 2>/dev/null | awk 'NR > 1 {print $1}'; }
for _ in $(seq 1 15); do meshed | grep -qx "vm-bare.student01" && break; sleep 2; done
list=$(meshed)
has() { grep -qx "$1" <<<"$list" && echo listed || echo absent; }
check "istioctl proxy-status lists the bare pod" listed "$(has "vm-bare.student01")"
check "istioctl proxy-status lists the deployment pod" listed "$(has "$deploypod.student01")"
check "istioctl proxy-status lists the pod with inject=false in the manifest" listed "$(has "vm-optout.student01")"
check "istioctl proxy-status does not list the mentor pod" absent "$(has "vm-mentor.mentor")"
check "istioctl proxy-status does not list the default pod" absent "$(has "vm-default.default")"
check "istioctl proxy-status does not list the default person=student pod" absent "$(has "vm-person.default")"

echo "== require-ro-rootfs with the sidecar"
check "student01: bare pod with a read-only app passes, sidecar included" "pass success" "$(report student01 vm-bare)"
check "student01: deployment pod reports only the app container" \
  "fail readOnlyRootFilesystem must be true; writable: app" "$(report student01 "$deploypod")"

[ $fail -eq 0 ] && echo "Mesh: all checks passed" || echo "Mesh: FAILED"
exit $fail
