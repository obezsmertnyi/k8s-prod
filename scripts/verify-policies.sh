#!/usr/bin/env bash
# Checks the person-label and require-ro-rootfs policies on the live cluster with throwaway pods.
# Exits non-zero if any answer differs from the expected one. Test pods are removed on exit.
set -uo pipefail

export KUBECONFIG="$PWD/out/admin.kubeconfig"
namespaces=(mentor student01 student02 student03 default)
mark=verify-policies   # label on every test pod, used for cleanup
fail=0

cleanup() {
  for ns in "${namespaces[@]}"; do
    kubectl delete pods -n "$ns" -l "$mark=run" --now --ignore-not-found >/dev/null 2>&1
  done
}
trap cleanup EXIT
trap 'exit 1' INT TERM

check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then printf '  ok    %-58s %s\n' "$1" "$3"
  else printf '  FAIL  %-58s %s (expected %s)\n' "$1" "$3" "$2"; fail=1; fi
}

pod() { # pod <namespace> <name> <readOnlyRootFilesystem true|false> [extra labels as JSON]
  local extra=${4:-}; [ -z "$extra" ] && extra='{}'
  kubectl apply -f - >/dev/null 2>&1 <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $2
  namespace: $1
  labels: $(jq -c --arg m "$mark" '. + {($m): "run"}' <<<"$extra")
spec:
  containers:
    - name: app
      image: busybox:1.37
      command: [sleep, "3600"]
      securityContext: {readOnlyRootFilesystem: $3}
      resources: {requests: {cpu: 10m, memory: 16Mi}}
EOF
  [ $? -eq 0 ] && echo admitted || echo denied
}

person() { # person <namespace> <name> -> value of the person label, or "none"
  kubectl get pod "$2" -n "$1" -o json 2>/dev/null |
    jq -r '(.metadata.labels // {}) | if has("person") then .person else "none" end'
}

report() { # report <namespace> <name> -> require-ro-rootfs result, waits up to 60 s for the report
  local uid i r=none
  uid=$(kubectl get pod "$2" -n "$1" -o jsonpath='{.metadata.uid}' 2>/dev/null)
  for i in $(seq 1 30); do
    r=$(kubectl get policyreport "$uid" -n "$1" -o json 2>/dev/null |
      jq -r '[.results[]? | select(.policy == "require-ro-rootfs") | .result] | first // "none"')
    [ "${r:-none}" != none ] && break
    sleep 2
  done
  echo "${r:-none}"
}

cleanup   # leftovers from an interrupted run

echo "== person-label"
pod student01 vp-student false >/dev/null
pod mentor vp-mentor false >/dev/null
pod default vp-default-set false '{"person": "student"}' >/dev/null
pod default vp-default-relabel false >/dev/null
pod student02 vp-student-wrong false '{"person": "mentor"}' >/dev/null
check "student01: new pod" student "$(person student01 vp-student)"
check "mentor: new pod" mentor "$(person mentor vp-mentor)"
check "default: manifest sets person=student" none "$(person default vp-default-set)"
got=ok; kubectl label pod vp-default-relabel -n default person=x >/dev/null 2>&1 || got=rejected
check "default: kubectl label person=x is accepted" ok "$got"
check "default: person label is gone after kubectl label" none "$(person default vp-default-relabel)"
check "student02: manifest sets person=mentor" student "$(person student02 vp-student-wrong)"

echo "== require-ro-rootfs (Audit)"
check "student03: writable rootfs pod is admitted" admitted "$(pod student03 vp-rw false)"
check "student03: read-only rootfs pod is admitted" admitted "$(pod student03 vp-ro true)"
check "student03: writable rootfs pod in the report" fail "$(report student03 vp-rw)"
check "student03: read-only rootfs pod in the report" pass "$(report student03 vp-ro)"

[ $fail -eq 0 ] && echo "Policies: all checks passed" || echo "Policies: FAILED"
exit $fail
