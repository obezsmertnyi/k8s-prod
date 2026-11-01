# Module 05: Observability and troubleshooting

This page is for the reviewer. It lists what the repository builds for Module 05, the decisions behind it, and the commands that prove each claim.

## What is built

| Task | What exists | Where |
|---|---|---|
| 1. A monitoring system in the cluster | kube-prometheus-stack (Prometheus, Alertmanager, Grafana, kube-state-metrics, node-exporter), Loki for logs, Grafana Alloy as the log and event shipper, and Mailpit as the mail catcher. Flux installs all of it as HelmReleases in the namespace `monitoring` | `infrastructure/monitoring/` |
| 2. A dashboard of node load by student namespaces | Grafana dashboard "Student namespaces: node load": CPU cores, share of the node's CPU, memory and pods per node and student namespace. A small demo load runs in each student namespace so the panels have data | `charts/observability/dashboards/node-load.json`, `charts/observability/templates/demo-load.yaml` |
| 3. A dashboard and an alarm when a pod reports a readonly root filesystem audit failure | Grafana dashboard "Read-only root filesystem audit" and the Loki alert `ReadOnlyRootFilesystemAuditFailed`, which Alertmanager sends by email. A Prometheus rule on the Kyverno metric is a cross-check | `charts/observability/dashboards/readonly-rootfs-audit.json`, `charts/observability/files/loki-rules.yaml`, `charts/observability/templates/kyverno-metrics.yaml` |

Everything reaches the cluster through Git, like the earlier modules. `make verify` has a new step, `scripts/verify-observability.sh`, and `make up` waits for the four new HelmReleases.

## Versions

| Component | Version | Pinned in |
|---|---|---|
| kube-prometheus-stack (Helm chart, OCI) | 92.17.0: Prometheus Operator v0.94.2, Prometheus v3.15.1, Alertmanager v0.34.2, Grafana 13.3.0, kube-state-metrics v2.20.0, node-exporter v1.12.1 | `infrastructure/monitoring/repositories.yaml` (`ref.tag`) |
| Loki (Helm chart, OCI) | 20.2.1: Loki 3.7.9 | `infrastructure/monitoring/repositories.yaml` |
| Grafana Alloy (Helm chart) | 1.15.0: Alloy v1.21.3 | `infrastructure/monitoring/releases.yaml` (`chart.spec.version`) |
| Mailpit | v1.33.0 | `infrastructure/monitoring/mailpit.yaml` |
| Kyverno, Istio, Flux, Kubernetes | unchanged: 1.19.2, 1.31.3, 2.10, v1.37.0 | Modules 02 to 04 |

Local tools are the same as in Module 04. `make lint` now also needs `jq`.

## Layout

```
infrastructure/monitoring/
  namespace.yaml      monitoring, no Pod Security label
  repositories.yaml   OCIRepository kube-prometheus-stack and loki, HelmRepository grafana
  releases.yaml       HelmReleases kube-prometheus-stack, loki, alloy
  mailpit.yaml        Deployment and Service of Mailpit
  networkpolicies.yaml  who may connect to the namespace (see Isolation)
releases/observability.yaml     HelmRelease of the local chart
charts/observability/
  dashboards/         the two Grafana dashboards (JSON)
  files/loki-rules.yaml           the Loki alert rule
  templates/          ConfigMaps for the dashboards and the rule, ServiceMonitor and PrometheusRule for Kyverno, demo load
clusters/k8s-prod/infrastructure.yaml   now with postBuild and a longer timeout
scripts/verify-observability.sh
```

The order of events on a new cluster:

1. The `infrastructure` Kustomization applies `infrastructure/`, which now includes `infrastructure/monitoring/`.
2. `kube-prometheus-stack` installs first. It also installs the Prometheus Operator CRDs (ServiceMonitor, PrometheusRule and others). They come from the chart's `crds` subchart and Flux applies them because the HelmRelease has `install.crds: CreateReplace` and `upgrade.crds: CreateReplace` (Helm alone never upgrades CRDs). On the lab, 10 CRDs were created this way.
3. `loki` waits for it (`dependsOn`), `alloy` waits for `loki`. Mailpit is a plain Deployment with no dependency: Alertmanager retries a mail until the SMTP server answers.
4. `infrastructure` has `wait: true`, so it is Ready only when all of them are. Its timeout is now 25 minutes: Kyverno, Istio and the monitoring stack together pull a lot of images on a new cluster.
5. `platform` starts after it. The new HelmRelease `observability` waits for the three monitoring releases (its ServiceMonitor and PrometheusRule need the CRDs, the Grafana and Loki sidecars read its ConfigMaps), for `tenants` (the student namespaces must exist) and for `kyverno-policies` (so the demo pods start with their Istio sidecar).

### Settings that stay out of Git

The alert mail goes to a recipient that is not written in the repository. The Alertmanager receiver has `to: ${ALERT_EMAIL:=alerts@k8s-prod.lab}`. The `infrastructure` Kustomization has `postBuild.substituteFrom` with the optional Secret `lab-settings` (in `flux-system`), so Flux replaces `${ALERT_EMAIL}` with the value of the key `ALERT_EMAIL` when it applies the manifests. Without the Secret the default `alerts@k8s-prod.lab` is used and nothing fails. `make flux` creates the Secret from the git-ignored `out/lab.env`:

```
ALERT_EMAIL=<the address that should receive the alert mail>
```

The delivery is simulated: Alertmanager's SMTP server is Mailpit inside the cluster, which catches the mail. Nothing leaves the cluster, whatever address is set. `scripts/verify-observability.sh` reads the same Secret to know which recipient to look for.

Flux substitutes every `${...}` in the manifests of that Kustomization, not only this one. There is no other `${` under `infrastructure/` (checked with `kubectl kustomize infrastructure | grep '\$'`). A new manifest that needs a literal `${` must write `$${`.

## Task 1: the monitoring system

| Piece | What it does here |
|---|---|
| Prometheus (one replica, 5 Gi volume, retention 2 days, scrape interval 30 s) | Scrapes the kubelet (cAdvisor), kube-state-metrics, node-exporter, the API server, CoreDNS and the monitoring components themselves, and the Kyverno metrics Services (ServiceMonitor in `charts/observability`) |
| Alertmanager | Keeps the chart's null receiver and the Watchdog heartbeat, and routes `ReadOnlyRootFilesystemAuditFailed` to the `email` receiver |
| Grafana | Data sources Prometheus, Alertmanager (both from the chart) and Loki (added). The sidecar loads every ConfigMap labelled `grafana_dashboard: "1"` from the namespace `monitoring` and from no other (see [Isolation](#isolation)). The chart's default dashboards are off to keep the lab small |
| Loki (single binary, filesystem, 5 Gi volume, retention 48 h) | Stores logs. Auth is off, so everything belongs to the tenant `fake`. The ruler evaluates the rules every 30 s and sends firing alerts to Alertmanager |
| Alloy (one replica) | Reads the logs of all pods through the Kubernetes API and the Kubernetes events, and pushes both to Loki |
| Mailpit | Catches the alert mail. SMTP on 1025, web UI and API on 8025 |

Choices worth knowing:

- **No scrape of etcd, controller-manager, scheduler and kube-proxy.** On kind they listen on the loopback of the control plane node and cannot be reached, so their targets would be down and their rules would fire. Their ServiceMonitors and rules are switched off. The alert `NodeClockNotSynchronising` is off too: the kind nodes share the clock of the Docker VM and report it as unsynchronised.
- **Alloy is one replica.** A DaemonSet without clustering would read every pod and every event once per node, and Loki would hold each line several times. Pod logs come through the API (`loki.source.kubernetes`), so Alloy needs no host path and runs in a plain namespace.
- **Loki rules come from ConfigMaps.** The chart's rules sidecar watches ConfigMaps labelled `loki_rule: "1"` in `monitoring` only (see [Isolation](#isolation)) and writes them to `/rules/fake`, the directory the ruler reads for the tenant `fake`. A new rule is a ConfigMap, with no Loki restart.
- **Prometheus picks up rules and monitors of any chart.** The `*SelectorNilUsesHelmValues` switches are `false`, so a ServiceMonitor or PrometheusRule without the `release` label of the stack is used too.
- **The Grafana admin password is not in Git.** The chart generates it into the Secret `kube-prometheus-stack-grafana` on the first install.
- **`monitoring` is excluded from `require-ro-rootfs`.** It is a platform namespace, like `kube-system`, `kyverno` and `istio-system`, and the audit is about workloads. Alloy's container does not set a read-only root filesystem (every other container in the namespace does), so without the exclusion the alert would fire for the platform's own pod. The namespace is added to `excludedNamespaces` of the `kyverno-policies` chart, with a test case (`pod-monitoring`, expected `skip`).

## Task 2: node load by student namespace

Dashboard "Student namespaces: node load" (`uid student-node-load`). The variable `namespace` lists the namespaces that match `student.*` (multi-select, default All). The metric `container_cpu_usage_seconds_total` and the others come from cAdvisor through the kubelet. On this chart the cAdvisor series carry the label `node` (the node of the pod), as do `kube_pod_info` and `kube_node_status_allocatable`, so no join is needed to get the node. `container!=""` leaves out the pod-level cgroup series.

| Panel | Query |
|---|---|
| CPU used (cores) | `sum by (node, namespace) (rate(container_cpu_usage_seconds_total{container!="", namespace=~"$namespace"}[$__rate_interval]))` |
| Share of the node's allocatable CPU | the query above, divided by `sum by (node) (kube_node_status_allocatable{resource="cpu"})` (`/ on (node) group_left ()`) |
| Memory working set | `sum by (node, namespace) (container_memory_working_set_bytes{container!="", namespace=~"$namespace"})` |
| Running pods | `count by (node, namespace) (kube_pod_info{namespace=~"$namespace"} and on (namespace, pod) (kube_pod_status_phase{namespace=~"$namespace", phase="Running"} == 1))` |
| Table "Now, per node and student namespace" | the four queries as instant queries, merged on the labels `node` and `namespace` |

The namespace is the unit, so a student's sidecars are counted with the student's pods.

### The demo load

Without a workload the student namespaces use almost nothing and the panels are flat. `charts/observability` therefore creates a Deployment `demo-load` in each student namespace: three replicas of a busybox shell loop with CPU requests of 25m and limits of 50m, memory limit 32 Mi. It is a student pod, so Kyverno marks it and Istio adds the sidecar. The container is non-root, drops all capabilities and has a read-only root filesystem: it passes Pod Security `baseline` and `restricted` and `require-ro-rootfs` reports no finding for it, so it never raises the alert.

The topology spread constraint is hard (`DoNotSchedule`, `maxSkew: 1` on the hostname, `nodeTaintsPolicy: Honor`), so there is one replica per worker and every node shows load for every student. A soft constraint (`ScheduleAnyway`) was tried first, with two replicas per namespace: the scheduler put all six pods on two of the three workers and the third node showed nothing. Whether the lab has three workers is the price: with fewer, a replica stays Pending.

## Task 3: the readonly root filesystem alert

### Why the alert is built on a Kubernetes event

The task asks for an alarm when "a pod's logs report" the failure. In Kyverno 1.19 the policy `require-ro-rootfs` runs in Audit mode, and an audit failure writes **no log line** at the default verbosity: the "creating event" message is only logged at verbosity 6, and the chart's default is 2. What Kyverno does emit is a Warning event with the reason `PolicyViolation`, one on the Pod and one on the policy. It also adds the result to the PolicyReport and to the metric `kyverno_validating_policy_results_total`.

So the signal is the event, and Alloy turns it into a log line: `loki.source.kubernetes_events` ships every event to Loki as a line of the stream `job="loki.source.kubernetes_events"`. The alert is then an ordinary LogQL rule over logs, which is what the module teaches (a Loki ruler, Alertmanager routing, a mail). The metric is kept as a cross-check, below.

The line, as it is in Loki for the Pod's event (seen on the lab):

```
name=probe-rw kind=Pod action=Resource Passed objectAPIversion=v1 eventRV=9477 reportinginstance=kyverno-admission-... reportingcontroller=kyverno-admission reason=PolicyViolation type=Warning msg="policy require-ro-rootfs/ fail: readOnlyRootFilesystem must be true; writable: probe-rw"
```

Stream labels: `job="loki.source.kubernetes_events"`, `namespace="student03"`, `instance`, `detected_level="warn"`. The event on the policy has no `namespace` label and a different message (`Pod student03/probe-rw: fail; ...`), so selecting the stream with `namespace=~".+"` and the token `policy require-ro-rootfs/` leaves exactly the Pod-side events. That token is the policy name in the text Kyverno writes, so it is already unique and the policy message in `charts/kyverno-policies` did not need to change.

### The rule

`charts/observability/files/loki-rules.yaml`:

```
sum by (namespace, pod) (
  count_over_time(
    {job="loki.source.kubernetes_events", namespace=~".+"}
      |= "reason=PolicyViolation" |= "policy require-ro-rootfs/"
      | logfmt | label_format pod=name
    [5m]
  )
) > 0
```

Labels `severity: warning`. The summary is "Pod `<pod>` in namespace `<namespace>` runs with a writable root filesystem". The rule fires at the first evaluation after Alloy has shipped the event (the ruler evaluates every 30 s) and resolves when five minutes pass without a new event. Kyverno emits the event when the pod is admitted and again when its background scan reads the pod, so one pod usually produces two lines. A pod that stays writable is reported again by later scans.

### From the alert to the mail

Alertmanager (`infrastructure/monitoring/releases.yaml`) has one route in front of the chart's defaults: `alertname = ReadOnlyRootFilesystemAuditFailed` goes to the receiver `email`, grouped by alertname and namespace, with a group wait of 10 s. Watchdog and the rest still go to the null receiver. The mail is sent through `mailpit.monitoring.svc:1025` without TLS, from `alertmanager@k8s-prod.lab`, to the recipient from `lab-settings` (see above), with the subject `[FIRING] ReadOnlyRootFilesystemAuditFailed in student03`. The body lists the pod, the summary and a link to the query. `send_resolved` is false, so the mailbox gets one mail per problem.

### The dashboard

"Read-only root filesystem audit" (`uid readonly-rootfs-audit`), variable `namespace` from the Loki label (default All):

| Panel | Query |
|---|---|
| Findings in the last 5 minutes | `sum(count_over_time({job="loki.source.kubernetes_events", namespace=~"$namespace"} \|= "reason=PolicyViolation" \|= "policy require-ro-rootfs/" [5m])) or vector(0)`. Red above 0: this is the alert condition |
| Alert state (Loki ruler) | Alert list on the Loki data source, filtered to `ReadOnlyRootFilesystemAuditFailed`: the rule while it is pending or firing, empty otherwise |
| Findings by namespace | `sum by (namespace) (count_over_time({...same selector...} [$__interval]))`, stacked bars |
| Same finding, from the Kyverno metric | `sum by (resource_namespace) (increase(kyverno_validating_policy_results_total{policy_name="require-ro-rootfs", result="fail", execution_cause="admission_request"}[$__rate_interval]))` |
| Pods with a finding in the time range | `sum by (namespace, name) (count_over_time({...same selector...} \| logfmt [$__range]))` as a table |
| Audit events (log lines) | the selector alone, as a log panel |

### The metric cross-check

`charts/observability/templates/kyverno-metrics.yaml` holds a ServiceMonitor for the metrics Services of Kyverno (port `metrics-port`) and a PrometheusRule `ReadOnlyRootFilesystemAuditFailedMetric`: the sum of `increase(kyverno_validating_policy_results_total{policy_name="require-ro-rootfs", result="fail", execution_cause="admission_request"}[5m])` per namespace, above 0. It looks at admission results only, because the background scan counts the same pod again each time it runs. It goes to the null receiver and shows up in Prometheus and in the Alertmanager UI, so the log path and the metric path can be compared.

One limit is known: `increase()` needs a series that already exists, and Kyverno creates the series for a namespace at its first failure. The first failure recorded for a namespace after a Kyverno restart is therefore not seen by this rule. The Loki rule has no such gap, which is one more reason the log path is the one that sends the mail. The verify script checks the counter itself (it must rise) and that the rule is loaded and healthy, not the state of this alert.

## Isolation

A student has the built-in `edit` role in their own namespace, so a student can create ConfigMaps and pods there. Two paths led from that into the monitoring stack, and both are closed.

**1. Rules and dashboards could be shipped from a student namespace.** The Loki rules sidecar (`searchNamespace: ALL`) and the Grafana dashboards sidecar (the chart sets `searchNamespace: ALL`) loaded every ConfigMap with their label from every namespace. A ConfigMap labelled `loki_rule` in `student01` became an alert rule in the ruler, and one labelled `grafana_dashboard` became a dashboard in Grafana (the sidecars read Secrets too). Now `infrastructure/monitoring/releases.yaml` sets `searchNamespace: monitoring` for the Loki rules sidecar, the Grafana dashboards sidecar and the Grafana data sources sidecar (its chart default is the sidecar's own namespace, written down so it stays so). `rbac.namespaced: true` on both charts turns the sidecars' ClusterRole (read ConfigMaps and Secrets everywhere) into a Role in `monitoring`. Our own ConfigMaps are rendered into `monitoring` because the `observability` HelmRelease has `targetNamespace: monitoring`; if they were rendered elsewhere the two dashboards and the Loki rule would be missing and `scripts/verify-observability.sh` would fail.

**2. Any pod could connect to the stack.** Loki has auth off, Prometheus and Alertmanager have none, Mailpit's web UI has none: a student pod could read the logs of every namespace from Loki or the caught mail from Mailpit. `infrastructure/monitoring/networkpolicies.yaml` adds three NetworkPolicies to `monitoring` (ingress only, egress stays open):

| Policy | Effect |
|---|---|
| `default-deny-ingress` | every pod in `monitoring` refuses connections. The next policy isolates the same pods on its own (any policy that selects a pod isolates it); the explicit deny keeps the intent visible and still closes the namespace if the allow list is ever removed |
| `allow-ingress-from-monitoring` | except from the pods of `monitoring` itself: Alloy to Loki, Grafana to Prometheus, Loki and Alertmanager, the Loki ruler to Alertmanager, Alertmanager to Mailpit, Prometheus scraping itself and kube-state-metrics |

Nothing else gets in. The Prometheus Operator admission webhook is turned off (`prometheusOperator.admissionWebhooks.enabled: false`): the API server would call it from a node address that no selector can name, so keeping it would mean opening its port to every source. PrometheusRules are validated by `make lint` before they reach the cluster. What needs no rule: kubelet probes (kindnet does not filter traffic generated by root on the node) and `kubectl port-forward` (the runtime opens it inside the pod's own network namespace). Mailpit's UI stays without a login: its own authentication would need a password in a Secret, and the policy already keeps pods out.

**What the policies do not cover.** node-exporter runs with `hostNetwork` on port 9100 of every node, and a NetworkPolicy cannot protect a host-network pod: node metrics stay readable from any pod, as before. The kubelet and the API server are not in `monitoring` and are not touched.

**Does kind enforce NetworkPolicy?** Yes, since kind v0.24.0: the release notes list "Out-of-the-box support for network policy via sigs.k8s.io/kube-network-policies". The kind v0.33.0 default CNI manifest (`pkg/build/nodeimage/const_cni.go`) runs `kindnetd` image `v20260820-69b56db7`, whose ClusterRole may list and watch `networkpolicies`, and `images/kindnetd/cmd/kindnetd/main.go` wires the standard NetworkPolicy evaluator into an nftables queue. One caveat decides how the proof must look: kindnetd starts that controller with `FailOpen: true`, and if the controller cannot be created it only logs "skipping network policies" and the cluster runs without enforcement. A policy that exists is therefore no proof that it works, which is why the script tests the behaviour.

**How the script proves it** (`scripts/verify-observability.sh`, section "isolation"):

- The three NetworkPolicies exist, and no kindnet pod logged "skipping network policies".
- A pod created in `student01` with student01's own kubeconfig, and a control pod created in `monitoring` by the admin, both run the same HTTP GET with a 15 s timeout. The control pod reaches Loki (`/ready`), Prometheus (`/-/ready`), Alertmanager (`/-/ready`), Grafana (`/api/health`) and Mailpit (`/readyz`); the student01 pod must not. Before that, the student01 pod must be Ready, be able to `exec`, and resolve `loki.monitoring`, so a "blocked" answer cannot be a dead pod or a DNS failure. The student01 pod has the Istio sidecar, so a blocked connection can show as a 503 from the proxy after its connect timeout instead of a plain timeout: any answer but a 2xx counts as blocked.
- The three sidecars have `NAMESPACE=monitoring`, and the service accounts of Grafana and Loki can list ConfigMaps in `monitoring` but neither ConfigMaps nor Secrets in `student01`. student01 cannot create a PrometheusRule or a ServiceMonitor (the Operator CRDs are not part of `edit`; Prometheus selects those of every namespace, so this must stay so).
- student01 creates a ConfigMap labelled `loki_rule` and one labelled `grafana_dashboard` in `student01`, then the admin creates the same two in `monitoring` as a control. When the control rule is in the ruler and the control dashboard is in Grafana, the script requires that the student's rule and dashboard are not.
- Everything the script creates carries the label `verify-observability=run` and is removed on exit, also after an interrupted run.

The checks can fail. Delete the two policies that close the namespace and look at the FAIL lines, then let Flux put them back:

```
kubectl delete networkpolicy default-deny-ingress allow-ingress-from-monitoring -n monitoring
scripts/verify-observability.sh                      # the five "student01 pod -> ..." lines fail
flux reconcile kustomization infrastructure --with-source
```

## Memory

Measured with `docker stats` on the four kind nodes, with the whole stack and the demo load running (about 30 minutes after the install):

| | Before Module 05 (Flux, Kyverno, Istio, idle) | With the stack and the demo load |
|---|---|---|
| control plane | 1.64 GiB | 1.76 GiB |
| workers | 0.56, 0.57 and 0.67 GiB | 0.87, 1.16 and 1.40 GiB |
| total | 3.44 GiB | 5.19 GiB of the 7.75 GiB of the Docker VM |

These are single snapshots, not averages, and node memory also holds page cache and image layers.

By working set (Prometheus, `container_memory_working_set_bytes`): the namespace `monitoring` holds 1.4 GiB (Grafana with its two sidecars 515 MiB, Prometheus 504 MiB with about 100 000 series, Loki 177 MiB, Alloy 85 MiB, the four node-exporters 42 MiB together, the rest under 40 MiB each). The nine demo pods with their sidecars in the student namespaces hold 293 MiB. No pod restarted. Requests and limits are set on every component (see `releases.yaml`), because the lab has no metrics-server and memory is the scarce resource.

## How to open the UIs

```
export KUBECONFIG=$PWD/out/admin.kubeconfig

# Grafana: http://localhost:3000, user admin, password from the Secret
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo

# Mailpit, the caught alert mails: http://localhost:8025
kubectl port-forward -n monitoring svc/mailpit 8025:8025

# Prometheus (http://localhost:9090) and Alertmanager (http://localhost:9093)
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093
```

Each command runs in its own terminal and stops with Ctrl+C. The dashboards are in the Grafana folder General, under Dashboards.

To see the alert by hand, create a pod with a writable root filesystem in a student namespace and watch Mailpit:

```
kubectl --kubeconfig out/kubeconfigs/student03.kubeconfig run demo-rw --image=busybox:1.37 -- sleep 3600
kubectl --kubeconfig out/kubeconfigs/student03.kubeconfig delete pod demo-rw
```

The mail arrives within about a minute.

## How to verify

One command, from the repository root, after `make up`:

```
make verify
```

It now has an observability step and the Flux check also covers the four new releases. The observability step on its own:

```
export KUBECONFIG=$PWD/out/admin.kubeconfig
scripts/verify-observability.sh
```

### 1. Local tests (before any deploy)

```
make test
make lint
```

`make test` runs the Kyverno tests: 23 now, one more than in Module 04. `kyverno test tests/kyverno/require-ro-rootfs` has the new case `pod-monitoring` (a writable pod in `monitoring`, expected `skip`). `make lint` runs `scripts/validate-manifests.sh`: `helm lint` and flux-schema on the new chart (ServiceMonitor and PrometheusRule are checked against the CRD schemas) and on every Flux layer (`infrastructure/`, `releases/`, `clusters/`), then `jq empty` on the dashboard files.

### 2. The stack on the cluster

`scripts/verify-observability.sh` uses a throwaway pod in `student03`, created with student03's own kubeconfig, and removes it on exit. It opens its port-forwards on free local ports and closes all of them on exit. The Grafana password is read from its Secret into a variable and is never printed. It checks:

- The four HelmReleases are Ready, Mailpit is ready, no pod in `monitoring` is unready, and the ServiceMonitor and PrometheusRule CRDs exist.
- The four time-series queries of the node-load dashboard, read from the dashboard file with `$namespace` set to `student.*`, return series for `student01`, `student02` and `student03`, every series has a `node` label, and the nodes are as many as the workers.
- Grafana is healthy, has both dashboards, and its Prometheus and Loki data sources answer (Alertmanager is asked through Grafana).
- Loki holds pod logs of `kube-system` and `kyverno`, and the ruler has loaded the rule.
- The pod with a writable root filesystem is admitted (Audit), and then, within bounded waits: its event line is in Loki, its own log line is in Loki, the Loki ruler alert for the pod is firing, Alertmanager holds the alert with the receiver `email`, Mailpit holds the mail to the configured recipient with the subject `[FIRING] ReadOnlyRootFilesystemAuditFailed in student03`, the Kyverno counter for `student03` has risen, and the cross-check rule is loaded and healthy.
- Isolation (section [Isolation](#isolation)): the stack refuses a pod of student01 and accepts the control pod in its own namespace, the sidecars read `monitoring` only, and a rule or dashboard ConfigMap made by student01 is not loaded.

## Live run

<!-- LIVE RUN: to be filled after `make up` from zero on the pushed branch. Paste the output of `make verify` and of `flux get helmreleases -A` here. -->
