#!/usr/bin/env bash
# Checks the GitOps setup on the live cluster: the Flux objects are Ready, the synced revision is the head of the
# pushed branch, and a RoleBinding deleted by hand comes back. Exits non-zero if any answer differs from the expected one.
set -uo pipefail

export KUBECONFIG="$PWD/out/admin.kubeconfig"
ns=flux-system
fail=0

check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then printf '  ok    %-58s %s\n' "$1" "$3"
  else printf '  FAIL  %-58s %s (expected %s)\n' "$1" "$3" "$2"; fail=1; fi
}

ready() { # ready <kind/name> -> True, False, or empty if the object is missing
  kubectl get -n "$ns" "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null
}

echo "== flux objects"
for o in fluxinstance/flux kustomization/flux-system kustomization/infrastructure kustomization/platform \
  helmrelease/kyverno helmrelease/istio-base helmrelease/istio-cni helmrelease/istiod \
  helmrelease/kube-prometheus-stack helmrelease/loki helmrelease/alloy \
  helmrelease/tenants helmrelease/kyverno-policies helmrelease/observability; do
  check "$o is Ready" True "$(ready "$o")"
done
others="cannot list them"
if all=$(kubectl get kustomization,helmrelease -A -o json 2>/dev/null); then
  others=$(jq -r '.items[] | select(([.status.conditions[]? | select(.type == "Ready")][0].status // "none") != "True") |
    "\(.kind)/\(.metadata.name)"' <<<"$all")
fi
check "every other Kustomization and HelmRelease is Ready" "" "$others"

echo "== git revision"
# Ask Flux to fetch now, then compare with the head of the branch on GitHub (read with the git remote of this clone).
ref=$(kubectl get gitrepository flux-system -n "$ns" -o jsonpath='{.spec.ref.name}' 2>/dev/null)
flux reconcile source git flux-system -n "$ns" >/dev/null 2>&1
want=""; [ -n "$ref" ] && want=$(git ls-remote origin "$ref" 2>/dev/null | awk -v r="$ref" '$2 == r {print $1}')
got=$(kubectl get gitrepository flux-system -n "$ns" -o jsonpath='{.status.artifact.revision}' 2>/dev/null | sed 's/.*://')
check "GitRepository flux-system is at the head of ${ref:-its branch}" "${want:-unknown}" "$got"

echo "== drift self-heal"
# Delete a RoleBinding by hand; the tenants release puts it back. The trap restores it if this script is interrupted.
# Only when Flux is healthy: with a broken Flux nothing would put the binding back.
if [ $fail -ne 0 ]; then
  echo "  FAIL  skipped: a check above failed, so Flux could not restore the RoleBinding"
  echo "Flux: FAILED"
  exit 1
fi
rb() { kubectl get rolebinding student01-edit -n student01 -o jsonpath='{.roleRef.name} {.subjects[0].name}' 2>/dev/null; }
# shellcheck disable=SC2329  # run by the EXIT trap below
restore() { [ -n "$(rb)" ] || flux reconcile helmrelease tenants -n "$ns" --force >/dev/null 2>&1; }
trap restore EXIT
trap 'exit 1' INT TERM
kubectl delete rolebinding student01-edit -n student01 >/dev/null 2>&1
check "student01-edit in student01 is deleted" "" "$(rb)"
flux reconcile helmrelease tenants -n "$ns" --force >/dev/null 2>&1
for _ in $(seq 1 30); do [ -n "$(rb)" ] && break; sleep 2; done
check "student01-edit is back after the reconcile (role subject)" "edit student01" "$(rb)"

[ $fail -eq 0 ] && echo "Flux: all checks passed" || echo "Flux: FAILED"
exit $fail
