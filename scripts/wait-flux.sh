#!/usr/bin/env bash
# Waits until the GitOps bootstrap has converged: the FluxInstance, the three Kustomizations and the ten
# HelmReleases are Ready. Exits non-zero after the timeout. Usage: wait-flux.sh [seconds, default 1800]
set -uo pipefail

export KUBECONFIG="$PWD/out/admin.kubeconfig"
deadline=$((SECONDS + ${1:-1800}))
objects=(
  fluxinstance/flux
  kustomization/flux-system kustomization/infrastructure kustomization/platform
  helmrelease/kyverno helmrelease/istio-base helmrelease/istio-cni helmrelease/istiod
  helmrelease/kube-prometheus-stack helmrelease/loki helmrelease/alloy
  helmrelease/tenants helmrelease/kyverno-policies helmrelease/observability
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
