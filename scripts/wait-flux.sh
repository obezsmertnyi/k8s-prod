#!/usr/bin/env bash
# Waits until the GitOps bootstrap has converged: the FluxInstance, the three Kustomizations and the three
# HelmReleases are Ready. Exits non-zero after the timeout. Usage: wait-flux.sh [seconds, default 1200]
set -uo pipefail

export KUBECONFIG="$PWD/out/admin.kubeconfig"
deadline=$((SECONDS + ${1:-1200}))
objects=(
  fluxinstance/flux
  kustomization/flux-system kustomization/infrastructure kustomization/platform
  helmrelease/kyverno helmrelease/tenants helmrelease/kyverno-policies
)

ready() { # ready <kind/name> -> True, False, or empty while the object does not exist yet
  kubectl get -n flux-system "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null
}

for o in "${objects[@]}"; do
  until [ "$(ready "$o")" = True ]; do
    if [ $SECONDS -ge $deadline ]; then
      echo "timed out waiting for $o" >&2
      kubectl get -n flux-system "$o" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}{"\n"}' >&2 2>/dev/null
      exit 1
    fi
    sleep 5
  done
  echo "  ready  $o"
done
echo "Flux: everything is Ready"
