# The lab's own admin kubeconfig, kept apart from ~/.kube/config.
export KUBECONFIG := $(CURDIR)/out/admin.kubeconfig

CLUSTER        := k8s-prod
# The branch Flux follows. Until the module PRs merge it is the top branch, afterwards main: make flux BRANCH=main
BRANCH         ?= $(shell git rev-parse --abbrev-ref HEAD)
# The repository Flux reads: the origin remote as an HTTPS URL, whatever form the remote has (git@github.com:o/r.git,
# git@<ssh alias>:o/r.git, ssh://, https with or without .git or credentials). Another one: make flux REPO_URL=https://...
REPO_URL       ?= $(shell git remote get-url origin 2>/dev/null | sed -E \
	-e 's|^[a-z+]+://||' -e 's|^[^@/]*@||' -e 's|^github\.com[^/:]*[:/]|https://github.com/|' -e 's|(\.git)?/?$$|.git|')
FLUX_OPERATOR  := 0.62.1
RENDERED       := .rendered
USERS          := mentor:mentors:mentor student01:students:student01 student02:students:student02 student03:students:student03

.PHONY: up cluster flux wait users verify render lint test down

up: cluster flux wait users verify

cluster:
	@mkdir -p out
	kind get clusters | grep -qx $(CLUSTER) || kind create cluster --config cluster/kind.yaml --kubeconfig $(KUBECONFIG)

# The only imperative step: the Flux Operator, the GitHub App secret and the FluxInstance. Everything else comes from Git.
# Without out/flux-app.env the repository must be public: Flux reads it over anonymous HTTPS, there is no secret and the
# FluxInstance loses provider and pullSecret.
flux:
	@case "$(REPO_URL)" in https://*) ;; *) echo "cannot derive an HTTPS URL from the origin remote: pass REPO_URL=https://github.com/<owner>/<repo>.git" >&2; exit 1 ;; esac
	helm upgrade --install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
		--version $(FLUX_OPERATOR) --namespace flux-system --create-namespace --wait --timeout 5m
	@if [ -s out/flux-app.env ]; then \
		set -a; . out/flux-app.env; set +a; \
		flux create secret githubapp flux-system --namespace flux-system --app-client-id "$$FLUX_APP_CLIENT_ID" \
			--app-installation-owner "$$FLUX_APP_OWNER" --app-private-key "$$FLUX_APP_KEY" --export | \
		kubectl apply --server-side --force-conflicts -f -; \
		anonymous=; \
	else \
		echo "no out/flux-app.env: public repository, Flux reads it without credentials"; \
		anonymous='/^ *provider:/d;/^ *pullSecret:/d'; \
	fi; \
	sed -e 's|@REPO_URL@|$(REPO_URL)|' -e 's|@BRANCH@|$(BRANCH)|' -e "$$anonymous" clusters/bootstrap/flux-instance.yaml | kubectl apply -f -

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
	scripts/validate-manifests.sh

test: render
	kyverno test tests/kyverno

down:
	kind delete cluster --name $(CLUSTER)
	rm -rf out/kubeconfigs out/admin.kubeconfig
