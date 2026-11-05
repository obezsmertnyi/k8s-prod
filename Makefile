# The lab's own admin kubeconfig, kept apart from ~/.kube/config.
export KUBECONFIG := $(CURDIR)/out/admin.kubeconfig

CLUSTER        := k8s-prod
KYVERNO_CHART  := 3.9.2
USERS          := mentor:mentors:mentor student01:students:student01 student02:students:student02 student03:students:student03

.PHONY: up cluster kyverno platform users verify test down

up: cluster kyverno platform users verify

cluster:
	@mkdir -p out
	kind get clusters | grep -qx $(CLUSTER) || kind create cluster --config cluster/kind.yaml --kubeconfig $(KUBECONFIG)

kyverno:
	helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update >/dev/null
	helm upgrade --install kyverno kyverno/kyverno --version $(KYVERNO_CHART) \
		--namespace kyverno --create-namespace --wait --timeout 10m

platform:
	kubectl apply -k platform/

users:
	@for u in $(USERS); do scripts/make-user.sh $$(echo $$u | tr ':' ' '); done

verify: test
	scripts/verify-rbac.sh
	scripts/verify-policies.sh

test:
	kyverno test tests/kyverno

down:
	kind delete cluster --name $(CLUSTER)
	rm -rf out/kubeconfigs out/admin.kubeconfig
