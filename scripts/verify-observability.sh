#!/usr/bin/env bash
# Checks the monitoring stack on the live cluster: the releases are Ready, Prometheus answers the node-load queries of the
# dashboard for every student namespace, Grafana has both dashboards, and a pod with a writable root filesystem, created
# with student03's own kubeconfig, travels the whole alert path: the Kubernetes event in Loki, the Loki ruler alert,
# Alertmanager, and the email in Mailpit. A last section checks the isolation of the stack: a pod of student01 cannot connect to Loki,
# Prometheus, Alertmanager, Grafana or Mailpit, and a ConfigMap of student01 labelled loki_rule or grafana_dashboard is not loaded.
# The test pods and ConfigMaps are removed and every port-forward is closed on exit.
# Exits non-zero if any answer differs from the expected one. Usage: verify-observability.sh
# shellcheck disable=SC2329  # cleanup runs from the EXIT trap, the query functions run through poll
set -uo pipefail

export KUBECONFIG="$PWD/out/admin.kubeconfig"
dir=out/kubeconfigs
mon=monitoring
fluxns=flux-system
mark=verify-observability   # label on every pod and ConfigMap the script creates, used for cleanup
pod=$mark-$(date +%s)
spod=$mark-student-$(date +%s)   # probe pod in student01, created with student01's own kubeconfig
cpod=$mark-control-$(date +%s)   # control pod in monitoring: the same probe from inside the namespace
alert=ReadOnlyRootFilesystemAuditFailed
dash=charts/observability/dashboards
fail=0
pids=()
tmp=$(mktemp -d)
pport='' gport='' aport='' lport='' mport='' gpw=''   # local ports of the port-forwards, set by forward

sweep() { # remove everything this script creates: the pods and ConfigMaps all carry the label $mark=run
  local ns
  for ns in student01 student03 "$mon"; do
    kubectl delete pods,configmaps -n "$ns" -l "$mark=run" --now --ignore-not-found >/dev/null 2>&1
  done
}

cleanup() {
  [ ${#pids[@]} -gt 0 ] && kill "${pids[@]}" 2>/dev/null
  sweep
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then printf '  ok    %-66s %s\n' "$1" "$3"
  else printf '  FAIL  %-66s %s (expected %s)\n' "$1" "$3" "$2"; fail=1; fi
}

ready() { # ready <kind/name> -> True, False, or empty if the object is missing
  kubectl get -n "$fluxns" "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null
}

forward() { # forward <service> <remote port> <variable>: port-forward on a free local port, port stored in the variable
  local log="$tmp/pf-$1.log" p=""
  kubectl port-forward -n "$mon" "svc/$1" ":$2" >"$log" 2>&1 &
  pids+=($!)
  for _ in $(seq 1 40); do
    p=$(sed -n 's/^Forwarding from 127.0.0.1:\([0-9]*\) ->.*/\1/p' "$log" | head -1)
    [ -n "$p" ] && break
    sleep 0.5
  done
  printf -v "$3" '%s' "$p"
}

panel_expr() { # panel_expr <panel id> -> the query of that panel of the node-load dashboard, with its variables filled in
  local e
  e=$(jq -r --argjson id "$1" '.panels[] | select(.id == $id) | .targets[0].expr' "$dash/node-load.json")
  e=${e//\$namespace/student.*}   # namespace = All
  printf '%s' "${e//\$__rate_interval/5m}"
}

poll() { # poll <seconds> <command...> -> the first non-empty output of the command, nothing at the timeout
  local end=$((SECONDS + $1)) out
  shift
  while :; do
    out=$("$@" 2>/dev/null)
    if [ -n "$out" ]; then echo "$out"; return; fi
    [ $SECONDS -ge $end ] && return
    sleep 3
  done
}

# The Grafana password is read from its Secret into a variable and handed to curl on stdin: not printed, not in argv.
gf() { printf 'user = "admin:%s"\n' "$gpw" | curl -s -K - "http://127.0.0.1:$gport$1"; }
prom() { curl -sG "http://127.0.0.1:$pport/api/v1/query" --data-urlencode "query=$1"; }
loki() { # loki <logql> -> the log lines (query_range, last 15 minutes) of the first stream
  curl -sG "http://127.0.0.1:$lport/loki/api/v1/query_range" --data-urlencode "query=$1" \
    --data-urlencode "start=$(($(date +%s) - 900))000000000" --data-urlencode limit=5 |
    jq -r '.data.result[0].values[]?[1]' | head -1
}

for c in kubectl jq curl; do command -v "$c" >/dev/null || { echo "$c is not installed" >&2; exit 1; }; done
sweep   # leftovers from an interrupted run

echo "== releases"
for o in helmrelease/kube-prometheus-stack helmrelease/loki helmrelease/alloy helmrelease/observability; do
  check "$o is Ready" True "$(ready "$o")"
done
check "Mailpit: ready replicas" 1 "$(kubectl get deployment mailpit -n $mon -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
check "pods in $mon that are not Ready" "" "$(kubectl get pods -n $mon -o json 2>/dev/null |
  jq -r '.items[] | select(.status.phase != "Succeeded" and ([.status.conditions[]? | select(.type == "Ready")][0].status // "False") != "True") | .metadata.name')"
check "Prometheus Operator CRDs: ServiceMonitor, PrometheusRule" \
  "prometheusrules.monitoring.coreos.com servicemonitors.monitoring.coreos.com" \
  "$(kubectl get crd prometheusrules.monitoring.coreos.com servicemonitors.monitoring.coreos.com -o name 2>/dev/null | sed 's|.*/||' | sort | paste -sd' ' -)"

forward kube-prometheus-stack-prometheus 9090 pport
forward kube-prometheus-stack-grafana 80 gport
forward kube-prometheus-stack-alertmanager 9093 aport
forward loki 3100 lport
forward mailpit 8025 mport
gpw=$(kubectl get secret kube-prometheus-stack-grafana -n $mon -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)
for v in pport gport aport lport mport; do
  [ -n "${!v}" ] || { echo "  FAIL  port-forward for $v did not start"; echo "Observability: FAILED"; exit 1; }
done

echo "== node load (the queries of the dashboard, run on Prometheus)"
# The expressions are read from the dashboard file, so what is tested is what the panels run. $namespace is All (student.*).
want="student01,student02,student03"
for id in 1 2 3 4; do
  title=$(jq -r --argjson id "$id" '.panels[] | select(.id == $id) | .title' "$dash/node-load.json")
  expr=$(panel_expr "$id")
  got=""
  for _ in $(seq 1 40); do   # a new demo pod needs a few scrapes before it shows
    got=$(prom "$expr" | jq -r '[.data.result[].metric.namespace] | unique | join(",")')
    [ "$got" = "$want" ] && break
    sleep 5
  done
  check "$title: namespaces with series" "$want" "$got"
  check "$title: every series has a node label" 0 "$(prom "$expr" | jq '[.data.result[] | select((.metric.node // "") == "")] | length')"
done
workers=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o name | wc -l | tr -d ' ')
check "CPU used: nodes with student load (one per worker)" "$workers" \
  "$(prom "$(panel_expr 1)" | jq -r '[.data.result[].metric.node] | unique | length')"

echo "== grafana"
check "Grafana is healthy" ok "$(gf /api/health | jq -r '.database // "none"')"
check "dashboard student-node-load" "Student namespaces: node load" \
  "$(gf /api/dashboards/uid/student-node-load | jq -r '.dashboard.title // "none"')"
check "dashboard readonly-rootfs-audit" "Read-only root filesystem audit" \
  "$(gf /api/dashboards/uid/readonly-rootfs-audit | jq -r '.dashboard.title // "none"')"
for ds in prometheus loki; do
  check "data source $ds answers" OK "$(gf "/api/datasources/uid/$ds/health" | jq -r '.status // "none"')"
done
# The Alertmanager data source has no health endpoint; ask Alertmanager through it.
check "data source alertmanager answers (Alertmanager version)" "$(kubectl get pod alertmanager-kube-prometheus-stack-alertmanager-0 -n $mon \
  -o jsonpath='{.spec.containers[?(@.name=="alertmanager")].image}' 2>/dev/null | sed 's/.*:v//')" \
  "$(gf /api/alertmanager/alertmanager/api/v2/status | jq -r '.versionInfo.version // "none"')"

echo "== logs in Loki"
got=$(curl -s "http://127.0.0.1:$lport/loki/api/v1/label/namespace/values" | jq -r '[.data[]? | select(. == "kube-system" or . == "kyverno")] | join(",")')
check "Loki holds pod logs of platform namespaces (kube-system, kyverno)" "kube-system,kyverno" "$got"
check "Loki rule $alert is loaded in the ruler" "$alert" \
  "$(curl -s "http://127.0.0.1:$lport/prometheus/api/v1/rules" | jq -r --arg a "$alert" '[.data.groups[].rules[] | select(.name == $a) | .name] | first // "none"')"

echo "== $alert, end to end (pod in student03, created with its own kubeconfig)"
before=$(prom 'sum(kyverno_validating_policy_results_total{policy_name="require-ro-rootfs", result="fail", execution_cause="admission_request", resource_namespace="student03"})' |
  jq -r '.data.result[0].value[1] // "0"')
out=$(kubectl --kubeconfig "$dir/student03.kubeconfig" apply -n student03 -f - 2>&1 <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  labels: {$mark: run}
spec:
  containers:
    - name: app
      image: busybox:1.37
      command: [sh, -c, "echo $mark-hello; sleep 3600"]
      resources: {requests: {cpu: 10m, memory: 16Mi}}
EOF
)
rc=$?
check "student03: pod with a writable root filesystem is admitted (Audit)" admitted "$([ $rc -eq 0 ] && echo admitted || echo "denied: $out")"

msg=$(poll 90 loki "{job=\"loki.source.kubernetes_events\", namespace=\"student03\"} |= \"policy require-ro-rootfs/\" |= \"name=$pod \"" |
  sed -n 's/.*reason=\(PolicyViolation\).* msg="\(.*\)".*/\1: \2/p')
check "event line in Loki (job loki.source.kubernetes_events)" \
  "PolicyViolation: policy require-ro-rootfs/ fail: readOnlyRootFilesystem must be true; writable: app" "${msg:-none}"
got=$(poll 90 loki "{namespace=\"student03\", pod=\"$pod\", container=\"app\"} |= \"$mark-hello\"")
check "the pod's own log line is in Loki" "$mark-hello" "$([[ $got == *"$mark-hello"* ]] && echo "$mark-hello" || echo none)"

lalert() { curl -s "http://127.0.0.1:$lport/prometheus/api/v1/alerts" |
  jq -r --arg a "$alert" --arg p "$pod" '[.data.alerts[] | select(.labels.alertname == $a and .labels.pod == $p)] | first | .state // empty'; }
got=$(poll 180 lalert)
check "Loki ruler: alert $alert for the pod" firing "${got:-none}"

amalert() { curl -s "http://127.0.0.1:$aport/api/v2/alerts" |
  jq -r --arg a "$alert" --arg p "$pod" '[.[] | select(.labels.alertname == $a and .labels.pod == $p)] | first |
    select(. != null) | .status.state + " " + ([.receivers[].name] | join(","))'; }
got=$(poll 90 amalert)
check "Alertmanager: alert state and receiver" "active email" "${got:-none}"

# The mail is found by the pod name, which is in the body. The recipient is not in Git: it is read from the Secret lab-settings,
# or is the default of the manifest when the Secret does not exist.
rcpt=$(kubectl get secret lab-settings -n $fluxns -o jsonpath='{.data.ALERT_EMAIL}' 2>/dev/null | base64 -d)
rcpt=${rcpt:-alerts@k8s-prod.lab}
mail() { curl -sG "http://127.0.0.1:$mport/api/v1/search" --data-urlencode "query=$pod" |
  jq -r --arg r "$rcpt" '[.messages[]? | select(([.To[].Address] | index($r)) != null)] | first | select(. != null) | .Subject'; }
got=$(poll 120 mail)
check "Mailpit: subject of the mail to the configured recipient" "[FIRING] $alert in student03" "${got:-none}"

rose() { prom "sum(kyverno_validating_policy_results_total{policy_name=\"require-ro-rootfs\", result=\"fail\", execution_cause=\"admission_request\", resource_namespace=\"student03\"}) > $before" |
  jq -r '.data.result[0].value[1] // empty'; }
got=$(poll 90 rose)
check "Prometheus: Kyverno fail counter for student03 rose (cross-check)" rose "$([ -n "$got" ] && echo rose || echo "unchanged at $before")"
rulehealth() { curl -s "http://127.0.0.1:$pport/api/v1/rules" |
  jq -r --arg n "${alert}Metric" '[.data.groups[].rules[] | select(.name == $n and .health == "ok") | .health] | first // empty'; }
got=$(poll 90 rulehealth)
check "Prometheus: cross-check rule ${alert}Metric is loaded and healthy" ok "${got:-none}"
kubectl delete pod "$pod" -n student03 --now --ignore-not-found >/dev/null 2>&1
check "test pod is removed" "" "$(kubectl get pods -n student03 -l "$mark=run" -o name 2>/dev/null)"

echo "== isolation: the stack accepts connections from its own namespace only (probe pod in student01, its own kubeconfig)"
sk=$dir/student01.kubeconfig
# The NetworkPolicies are enforced by kindnet (kube-network-policies). If its controller did not start, the policies are inert and the
# "blocked" checks below fail, which is what they are for.
check "NetworkPolicies in $mon" "allow-ingress-from-monitoring default-deny-ingress" \
  "$(kubectl get networkpolicy -n $mon -o name 2>/dev/null | sed 's|.*/||' | sort | paste -sd' ' -)"
check "kindnet: no node logged 'skipping network policies'" 0 \
  "$(kubectl logs -n kube-system -l app=kindnet --tail=-1 2>/dev/null | grep -c 'skipping network policies')"

# A pod that passes Pod Security and the read-only root filesystem audit, so it raises no alert. In student01 it gets the Istio
# sidecar like any student pod; the probe is a plain HTTP GET with a timeout, and anything but a 2xx answer counts as blocked.
probe_pod() { cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $1
  labels: {$mark: run}
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: app
      image: busybox:1.37
      command: [sleep, "3600"]
      resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {memory: 32Mi}}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: {drop: [ALL]}
EOF
}
reach() { # reach <kubeconfig> <namespace> <pod> <url> -> reachable (HTTP 2xx) or blocked
  if kubectl --kubeconfig "$1" exec -n "$2" "$3" -c app -- timeout 15 wget -q -T 5 -O /dev/null "$4" >/dev/null 2>&1 </dev/null
  then echo reachable; else echo blocked; fi
}

out=$(probe_pod "$spod" | kubectl --kubeconfig "$sk" apply -n student01 -f - 2>&1)
rc=$?
check "student01: probe pod is created with its own kubeconfig" created "$([ $rc -eq 0 ] && echo created || echo "denied: $out")"
out=$(probe_pod "$cpod" | kubectl apply -n $mon -f - 2>&1)
rc=$?
check "$mon: control pod is created (admin)" created "$([ $rc -eq 0 ] && echo created || echo "denied: $out")"
kubectl wait --for=condition=Ready "pod/$spod" -n student01 --timeout=120s >/dev/null 2>&1
kubectl wait --for=condition=Ready "pod/$cpod" -n $mon --timeout=120s >/dev/null 2>&1
check "student01 probe pod is Ready" True \
  "$(kubectl get pod "$spod" -n student01 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
check "$mon control pod is Ready" True \
  "$(kubectl get pod "$cpod" -n $mon -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
# Without this a "blocked" answer could come from a pod that cannot exec or resolve names, and not from the policy.
check "student01 probe pod: exec works and loki.$mon resolves" resolved \
  "$(kubectl --kubeconfig "$sk" exec -n student01 "$spod" -c app -- nslookup "loki.$mon.svc.cluster.local" >/dev/null 2>&1 </dev/null && echo resolved || echo failed)"
for t in "loki|http://loki.$mon.svc:3100/ready" \
  "prometheus|http://kube-prometheus-stack-prometheus.$mon.svc:9090/-/ready" \
  "alertmanager|http://kube-prometheus-stack-alertmanager.$mon.svc:9093/-/ready" \
  "grafana|http://kube-prometheus-stack-grafana.$mon.svc:80/api/health" \
  "mailpit|http://mailpit.$mon.svc:8025/readyz"; do
  check "control pod in $mon -> ${t%%|*}" reachable "$(reach "$KUBECONFIG" $mon "$cpod" "${t#*|}")"
  check "student01 pod -> ${t%%|*}" blocked "$(reach "$sk" student01 "$spod" "${t#*|}")"
done

echo "== isolation: the sidecars read this namespace only, and a student cannot load a rule or a dashboard"
sidecar_ns() { # sidecar_ns <workload> <container> -> the namespace the sidecar searches
  kubectl get "$1" -n $mon -o jsonpath="{.spec.template.spec.containers[?(@.name==\"$2\")].env[?(@.name==\"NAMESPACE\")].value}" 2>/dev/null
}
can() { kubectl auth can-i "$1" "$2" -n "$3" --as "system:serviceaccount:$mon:$4" 2>/dev/null; }   # can <verb> <resource> <namespace> <sa>
check "Grafana dashboards sidecar searches only $mon" $mon "$(sidecar_ns deployment/kube-prometheus-stack-grafana grafana-sc-dashboard)"
check "Grafana data sources sidecar searches only $mon" $mon "$(sidecar_ns deployment/kube-prometheus-stack-grafana grafana-sc-datasources)"
check "Loki rules sidecar searches only $mon" $mon "$(sidecar_ns statefulset/loki loki-sc-rules)"
check "Grafana service account lists: ConfigMaps in $mon, ConfigMaps and Secrets in student01" "yes no no" \
  "$(can list configmaps $mon kube-prometheus-stack-grafana) $(can list configmaps student01 kube-prometheus-stack-grafana) $(can list secrets student01 kube-prometheus-stack-grafana)"
check "Loki service account lists: ConfigMaps in $mon, ConfigMaps and Secrets in student01" "yes no no" \
  "$(can list configmaps $mon loki) $(can list configmaps student01 loki) $(can list secrets student01 loki)"
# The Prometheus Operator CRDs are not part of `edit` (the chart's createAggregateClusterRoles is false). If they were, a student could
# add rules and scrape targets, because Prometheus selects the PrometheusRules and ServiceMonitors of every namespace.
check "student01 cannot create a PrometheusRule or a ServiceMonitor" "no no" "$(for r in prometheusrules servicemonitors; do
  kubectl --kubeconfig "$sk" auth can-i create "$r.monitoring.coreos.com" -n student01 2>/dev/null; done | paste -sd' ' -)"

# Two pairs of ConfigMaps of the same shape: the student's, made by student01 in student01, and a control made by the admin in monitoring.
# When the control has been loaded, the sidecar has had its chance to load the student's too, so "not loaded" is not just "not yet".
out=$(kubectl --kubeconfig "$sk" apply -n student01 -f - 2>&1 <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: $mark-student-rule
  labels: {loki_rule: "1", $mark: run}
data:
  student-rule.yaml: |
    groups:
      - name: $mark-student
        rules:
          - alert: StudentInjectedRule
            expr: sum(count_over_time({namespace="$mark-none"} [1m])) > 0
            for: 1m
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: $mark-student-dashboard
  labels: {grafana_dashboard: "1", $mark: run}
data:
  student-dashboard.json: |
    {"uid": "student-injected-dash", "title": "Injected by student01", "schemaVersion": 39, "panels": []}
EOF
)
rc=$?
check "student01: ConfigMaps labelled loki_rule and grafana_dashboard are created" created "$([ $rc -eq 0 ] && echo created || echo "denied: $out")"
sleep 5
out=$(kubectl apply -n $mon -f - 2>&1 <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: $mark-control-rule
  labels: {loki_rule: "1", $mark: run}
data:
  control-rule.yaml: |
    groups:
      - name: $mark-control
        rules:
          - alert: VerifyObservabilityControl
            expr: sum(count_over_time({namespace="$mark-none"} [1m])) > 0
            for: 1m
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: $mark-control-dashboard
  labels: {grafana_dashboard: "1", $mark: run}
data:
  control-dashboard.json: |
    {"uid": "verify-control-dash", "title": "Verify observability control", "schemaVersion": 39, "panels": []}
EOF
)
rc=$?
check "$mon: the control ConfigMaps are created (admin)" created "$([ $rc -eq 0 ] && echo created || echo "denied: $out")"
lrule() { curl -s "http://127.0.0.1:$lport/prometheus/api/v1/rules" |
  jq -r --arg n "$1" '[.data.groups[].rules[]? | select(.name == $n) | .name] | first // empty'; }
gdash() { gf "/api/dashboards/uid/$1" | jq -r '.dashboard.uid // empty'; }
got=$(poll 120 lrule VerifyObservabilityControl)
check "Loki ruler loads the rule ConfigMap of $mon (control)" VerifyObservabilityControl "${got:-none}"
got=$(lrule StudentInjectedRule)
check "Loki ruler does not load the rule ConfigMap of student01" none "${got:-none}"
got=$(poll 120 gdash verify-control-dash)
check "Grafana loads the dashboard ConfigMap of $mon (control)" verify-control-dash "${got:-none}"
got=$(gdash student-injected-dash)
check "Grafana does not load the dashboard ConfigMap of student01" none "${got:-none}"
sweep
check "isolation test pods and ConfigMaps are removed" "" "$(for n in student01 $mon; do kubectl get pods,configmaps -n "$n" -l "$mark=run" -o name 2>/dev/null; done)"

[ $fail -eq 0 ] && echo "Observability: all checks passed" || echo "Observability: FAILED"
exit $fail
