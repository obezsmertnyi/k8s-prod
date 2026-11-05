#!/usr/bin/env bash
# Creates a Kubernetes user as a client certificate signed by the cluster CA (CSR API) and writes its kubeconfig.
# Usage: make-user.sh <user> <group> <default-namespace>
# Output: out/kubeconfigs/<user>.kubeconfig (holds the private key; git-ignored, never committed).
set -euo pipefail

user=$1 group=$2 namespace=$3
days=30
dir=out/kubeconfigs
mkdir -p "$dir/keys" && chmod 700 "$dir/keys"
key=$dir/keys/$user.key

[ -s "$key" ] || openssl ecparam -name prime256v1 -genkey -noout -out "$key" 2>/dev/null
chmod 600 "$key"
csr=$(openssl req -new -key "$key" -subj "/CN=$user/O=$group" | base64 | tr -d '\n')

# A CSR object is immutable once approved, so a re-run replaces it.
kubectl delete csr "$user" --ignore-not-found >/dev/null
kubectl apply -f - >/dev/null <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: $user
spec:
  request: $csr
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: $((days * 86400))
  usages: [client auth]
EOF
kubectl certificate approve "$user" >/dev/null

cert=""
for _ in $(seq 1 30); do
  cert=$(kubectl get csr "$user" -o jsonpath='{.status.certificate}')
  [ -n "$cert" ] && break
  sleep 1
done
[ -n "$cert" ] || { echo "CSR $user was not signed" >&2; exit 1; }

kc=$dir/$user.kubeconfig
server=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')
kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "$dir/keys/ca.crt"
echo "$cert" | base64 -d > "$dir/keys/$user.crt"

rm -f "$kc"
KUBECONFIG=$kc kubectl config set-cluster k8s-prod --server="$server" \
  --certificate-authority="$dir/keys/ca.crt" --embed-certs=true >/dev/null
KUBECONFIG=$kc kubectl config set-credentials "$user" \
  --client-certificate="$dir/keys/$user.crt" --client-key="$key" --embed-certs=true >/dev/null
KUBECONFIG=$kc kubectl config set-context "$user@k8s-prod" --cluster=k8s-prod --user="$user" \
  --namespace="$namespace" >/dev/null
KUBECONFIG=$kc kubectl config use-context "$user@k8s-prod" >/dev/null
chmod 600 "$kc"
echo "$kc: user $user, group $group, namespace $namespace, valid $days days"
