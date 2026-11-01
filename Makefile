# The lab's own admin kubeconfig, kept apart from ~/.kube/config.
export KUBECONFIG := $(CURDIR)/out/admin.kubeconfig

CLUSTER        := k8s-prod
# The branch Flux follows. Until the module PRs merge it is the top branch, afterwards main: make flux BRANCH=main
BRANCH         ?= $(shell git rev-parse --abbrev-ref HEAD)
FLUX_OPERATOR  := 0.62.1
RENDERED       := .rendered
CRD_SCHEMAS    := https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json
KUBECONFORM    := kubeconform -strict -summary -schema-location default -schema-location '$(CRD_SCHEMAS)'
USERS          := mentor:mentors:mentor student01:students:student01 student02:students:student02 student03:students:student03

.PHONY: up cluster flux wait users verify render lint test down

up: cluster flux wait users verify

cluster:
	@mkdir -p out
	kind get clusters | grep -qx $(CLUSTER) || kind create cluster --config cluster/kind.yaml --kubeconfig $(KUBECONFIG)

# The only imperative step: the Flux Operator, the GitHub App secret and the FluxInstance. Everything else comes from Git.
flux:
	@test -s out/flux-app.env || { echo "out/flux-app.env is missing: see One-time setup in the README" >&2; exit 1; }
	helm upgrade --install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
		--version $(FLUX_OPERATOR) --namespace flux-system --create-namespace --wait --timeout 5m
	@set -a; . out/flux-app.env; set +a; \
	flux create secret githubapp flux-system --namespace flux-system --app-client-id "$$FLUX_APP_CLIENT_ID" \
		--app-installation-owner "$$FLUX_APP_OWNER" --app-private-key "$$FLUX_APP_KEY" --export | \
	kubectl apply --server-side --force-conflicts -f -
	sed 's|@BRANCH@|$(BRANCH)|' clusters/bootstrap/flux-instance.yaml | kubectl apply -f -

wait:
	scripts/wait-flux.sh

users:
	@for u in $(USERS); do scripts/make-user.sh $$(echo $$u | tr ':' ' '); done

verify: test
	scripts/verify-rbac.sh
	scripts/verify-policies.sh
	scripts/verify-mesh.sh
	scripts/verify-flux.sh

# The unit tests run on what the charts render, not on a copy of the policies.
render:
	rm -rf $(RENDERED)
	helm template kyverno-policies charts/kyverno-policies --output-dir $(RENDERED)

lint:
	helm lint charts/tenants charts/kyverno-policies
	helm template tenants charts/tenants | $(KUBECONFORM)
	helm template kyverno-policies charts/kyverno-policies | $(KUBECONFORM)
	kubectl kustomize infrastructure | $(KUBECONFORM)
	kubectl kustomize releases | $(KUBECONFORM)
	$(KUBECONFORM) clusters

test: render
	kyverno test tests/kyverno

down:
	kind delete cluster --name $(CLUSTER)
	rm -rf out/kubeconfigs out/admin.kubeconfig
