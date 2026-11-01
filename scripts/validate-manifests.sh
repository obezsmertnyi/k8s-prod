#!/usr/bin/env bash
# Validate what Flux will apply. Every Helm chart under charts/ is linted and rendered, every directory with a
# kustomization file is built, and the result is checked with flux-schema against its built-in catalog (Kubernetes
# and Flux kinds) and the community CRD catalog (Kyverno and others). A kind with no schema fails the run, and the
# CEL rules of the schemas are evaluated, as the API server would.
#
# The check runs on a copy of the files git tracks, not on the working tree. Flux only sees what git carries, so a
# kustomization that references an ignored or untracked file would pass here and break in the cluster; on the copy
# it fails the same way.
#
# Needs git, helm and flux-schema (a release binary, or the Flux CLI plugin: flux plugin install schema).
# Schemas are fetched over HTTPS, so it needs network. VERBOSE=1 lists every document, not only the failures.
# CRD_CATALOG overrides the community catalog base URL (flux-schema appends {{.Group}}/{{.Kind}}_{{.Version}}.json).
set -euo pipefail

CRD_CATALOG="${CRD_CATALOG:-https://raw.githubusercontent.com/datreeio/CRDs-catalog/main}"
# Directories Flux syncs as plain manifests (no kustomization file): validated file by file.
PLAIN_DIRS="clusters"

fs_validate() {
  if [ -n "${VERBOSE:-}" ]; then
    fluxschema validate -v -s default -s "$CRD_CATALOG" "$@"
  else
    fluxschema validate -s default -s "$CRD_CATALOG" "$@"
  fi
}

cd "$(git rev-parse --show-toplevel)"

# Copy the tracked files, with their working-tree content, and work there.
snap=$(mktemp -d "${TMPDIR:-/tmp}/validate-manifests.XXXXXX")
trap 'rm -rf "$snap"' EXIT
git ls-files -z | while IFS= read -r -d '' f; do
  if [ -e "$f" ] || [ -L "$f" ]; then printf '%s\0' "$f"; fi
done | tar -cf - --null -T - | tar -xf - -C "$snap"
cd "$snap"
snap_real=$(pwd -P)

# Reports name files relative to the repository, not to the temporary copy.
show() { printf '%s\n' "$1" | sed -e "s|$snap_real/||g" -e "s|$snap/||g"; }

charts=""
if [ -d charts ]; then
  charts=$(find charts -mindepth 2 -maxdepth 2 -name Chart.yaml | sort)
fi

# Kustomization directories, anywhere but under charts/ and hidden directories. A Component cannot be built alone.
kustomizations=""
for f in $(find . -mindepth 1 \( -path ./charts -o -name '.*' \) -prune -o \
  \( -name kustomization.yaml -o -name kustomization.yml -o -name Kustomization \) -type f -print | sort); do
  if grep -qE '^kind:[[:space:]]*Component' "$f"; then continue; fi
  d=$(dirname "$f")
  d=${d#./}
  # Inside a plain directory the walk below builds it already.
  skip=""
  for p in $PLAIN_DIRS; do
    case "$d" in "$p" | "$p"/*) skip=1 ;; esac
  done
  if [ -z "$skip" ]; then kustomizations="$kustomizations $d"; fi
done

plain=""
for p in $PLAIN_DIRS; do
  if [ -d "$p" ]; then plain="$plain $p"; fi
done

if [ -z "$charts" ] && [ -z "${kustomizations# }" ] && [ -z "${plain# }" ]; then
  echo "nothing to validate: no charts, kustomizations or Flux manifests in this tree"
  exit 0
fi

if command -v flux-schema >/dev/null 2>&1; then
  fluxschema() { flux-schema "$@"; }
elif command -v flux >/dev/null 2>&1 && flux schema --help >/dev/null 2>&1; then
  fluxschema() { flux schema "$@"; }
else
  echo "flux-schema not found. Install the Flux CLI plugin (flux plugin install schema)" >&2
  echo "or a release binary from https://github.com/fluxcd/flux-schema/releases" >&2
  exit 2
fi
command -v helm >/dev/null 2>&1 || { echo "helm not found" >&2; exit 2; }

echo "flux-schema: $(fluxschema --version)"
echo "schemas: default (built-in), $CRD_CATALOG"

failed=""
fail() { failed="$failed
  $1"; }

# One directory: a kustomization is built, a plain directory is read file by file.
validate_dir() {
  printf '\n==> %s %s\n' "$2" "$1"
  if out=$(fs_validate "$1" 2>&1); then
    show "$out"
  else
    show "$out"
    if printf '%s' "$out" | grep -q 'kustomize build error'; then
      echo "hint: the build ran on the files git tracks. Check that every file the kustomization references is committed" >&2
      echo "      and not ignored (git ls-files <file>, git check-ignore -v <file>)." >&2
    fi
    fail "$2 $1"
  fi
}

for c in $charts; do
  chart=$(dirname "$c")
  printf '\n==> chart %s\n' "$chart"
  if ! helm lint "$chart"; then fail "chart $chart (helm lint)"; continue; fi
  if ! helm template "$(basename "$chart")" "$chart" >.rendered.yaml; then fail "chart $chart (helm template)"; continue; fi
  if out=$(fs_validate <.rendered.yaml 2>&1); then
    show "$out"
  else
    show "$out"
    fail "chart $chart"
  fi
done

for d in $kustomizations; do validate_dir "$d" kustomization; done
for d in $plain; do validate_dir "$d" manifests; done

if [ -n "$failed" ]; then
  printf '\nvalidation failed:%s\n' "$failed" >&2
  exit 1
fi
printf '\nall manifests valid\n'
