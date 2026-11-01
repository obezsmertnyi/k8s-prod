#!/usr/bin/env bash
# Checks the RBAC matrix with each person's own kubeconfig (real client certificates, not impersonation).
# Exits non-zero if any answer differs from the expected one.
set -uo pipefail

dir=out/kubeconfigs
namespaces=(mentor student01 student02 student03 default kube-system)
fail=0

# expected[user:namespace] = rw | ro | -   (absent = -)
declare -A expected=(
  [mentor:mentor]=rw [mentor:student01]=rw [mentor:student02]=rw [mentor:student03]=rw
  [student01:student01]=rw
  [student03:student03]=rw
  [student02:student02]=rw [student02:student01]=ro [student02:default]=ro
)

can() { kubectl --kubeconfig "$dir/$1.kubeconfig" auth can-i "${@:2}" 2>/dev/null; }

check() { # check <label> <expected yes|no> <actual yes|no>
  if [ "$2" = "$3" ]; then printf '  ok    %-58s %s\n' "$1" "$3"
  else printf '  FAIL  %-58s %s (expected %s)\n' "$1" "$3" "$2"; fail=1; fi
}

for user in mentor student01 student02 student03; do
  echo "== $user ($(kubectl --kubeconfig "$dir/$user.kubeconfig" auth whoami -o jsonpath='{.status.userInfo.groups}'))"
  for ns in "${namespaces[@]}"; do
    want=${expected[$user:$ns]:--}
    read=no; write=no
    [ "$want" != "-" ] && read=yes
    [ "$want" = "rw" ] && write=yes
    check "$ns: get pods" $read "$(can $user get pods -n "$ns")"
    check "$ns: list secrets" $write "$(can $user list secrets -n "$ns")"
    check "$ns: create deployments" $write "$(can $user create deployments.apps -n "$ns")"
    check "$ns: delete pods" $write "$(can $user delete pods -n "$ns")"
  done
  own=$(kubectl --kubeconfig "$dir/$user.kubeconfig" config view --minify -o jsonpath='{..namespace}')
  check "cluster: * * (cluster-admin)" no "$(can $user '*' '*' --all-namespaces)"
  # Cluster-scoped questions are asked with --all-namespaces: inside a namespace, can-i would answer for that
  # namespace's own object (view/edit may read their own Namespace), not for the cluster-wide list.
  check "cluster: create clusterrolebindings" no "$(can $user create clusterrolebindings --all-namespaces)"
  check "cluster: list namespaces" no "$(can $user list namespaces --all-namespaces)"
  check "cluster: list nodes" no "$(can $user list nodes --all-namespaces)"
  check "$own: create rolebindings (no self-escalation)" no "$(can $user create rolebindings -n "$own")"
  check "$own: impersonate users" no "$(can $user impersonate users)"
done

echo "== real API calls"
call() { # call <label> <expected ok|forbidden> <user> <kubectl args...>
  local out; out=$(kubectl --kubeconfig "$dir/$3.kubeconfig" "${@:4}" 2>&1)
  local got=ok; grep -qi 'forbidden' <<<"$out" && got=forbidden
  check "$1" "$2" "$got"
}
call "student01 creates a ConfigMap in student01" ok student01 create configmap rbac-probe -n student01
call "student01 creates a ConfigMap in student03" forbidden student01 create configmap rbac-probe -n student03
call "student02 lists pods in student01" ok student02 get pods -n student01
call "student02 creates a ConfigMap in student01" forbidden student02 create configmap rbac-probe -n student01
call "student02 lists pods in default" ok student02 get pods -n default
call "mentor creates a ConfigMap in student02" ok mentor create configmap rbac-probe -n student02
call "mentor lists pods in kube-system" forbidden mentor get pods -n kube-system
call "student03 lists all namespaces" forbidden student03 get namespaces
kubectl delete configmap rbac-probe -n student01 --ignore-not-found >/dev/null
kubectl delete configmap rbac-probe -n student02 --ignore-not-found >/dev/null

echo "== pod security"
# student01 has edit in student01, so a denial here can only come from Pod Security admission.
mark=verify-rbac   # label on every pod made in this section, used for cleanup
cleanup() { kubectl delete pods -n student01 -l "$mark=run" --now --ignore-not-found >/dev/null 2>&1; }
trap cleanup EXIT
trap 'exit 1' INT TERM
cleanup
node=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}')
admit() { # admit <label> <expected denied|admitted> <pod name> <extra container fields JSON> <extra pod spec fields JSON>
  local out rc got=error
  out=$(jq -n --arg n "$3" --arg m "$mark" --argjson c "$4" --argjson s "$5" '{apiVersion: "v1", kind: "Pod",
      metadata: {name: $n, labels: {($m): "run"}},
      spec: ({containers: [{name: "c", image: "busybox:1.37", command: ["sleep", "3600"],
        resources: {requests: {cpu: "10m", memory: "16Mi"}}} + $c]} + $s)}' |
    kubectl --kubeconfig "$dir/student01.kubeconfig" create -n student01 -f - 2>&1); rc=$?
  # Admitted is the exit code: restricted warnings also name PodSecurity but do not block the pod.
  [ $rc -eq 0 ] && got=admitted
  [ $rc -ne 0 ] && grep -q 'violates PodSecurity' <<<"$out" && got=denied
  check "$1" "$2" "$got"
}
admit "student01 creates a privileged pod" denied rbac-probe-privileged '{"securityContext": {"privileged": true}}' '{}'
admit "student01 creates a hostPath / pod on the control plane" denied rbac-probe-hostpath \
  '{"volumeMounts": [{"name": "host", "mountPath": "/host", "readOnly": true}]}' \
  "$(jq -cn --arg n "$node" '{nodeName: $n, volumes: [{name: "host", hostPath: {path: "/"}}],
    tolerations: [{key: "node-role.kubernetes.io/control-plane", operator: "Exists", effect: "NoSchedule"}]}')"
admit "student01 creates a hostNetwork pod" denied rbac-probe-hostnet '{}' '{"hostNetwork": true}'
admit "student01 creates an ordinary pod" admitted rbac-probe-plain '{}' '{}'
cleanup
# Dry run: authorization is decided the same way, and a failed check cannot leave the namespace relaxed.
call "student01 relabels student01 to privileged" forbidden student01 label namespace student01 \
  pod-security.kubernetes.io/enforce=privileged --overwrite --dry-run=server
# Read with the admin kubeconfig: dropping the label from any person namespace must fail the script.
for ns in mentor student01 student02 student03; do
  check "$ns: pod security enforce label" baseline \
    "$(kubectl get namespace "$ns" -o json | jq -r '.metadata.labels["pod-security.kubernetes.io/enforce"] // "none"')"
done

echo "== no cluster-wide binding names a person"
bound=$(kubectl get clusterrolebindings -o json | jq -r '.items[] | select(any(.subjects[]?;
  (.kind == "User" and (.name | test("^(mentor|student0[1-3])$"))) or
  (.kind == "Group" and (.name == "mentors" or .name == "students")))) | .metadata.name')
check "ClusterRoleBindings for mentor/students/groups" "" "$bound"

[ $fail -eq 0 ] && echo "RBAC: all checks passed" || echo "RBAC: FAILED"
exit $fail
