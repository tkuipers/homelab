# Observability (Grafana LGTM, self-hosted)

Logs, metrics, traces, dashboards and alerts for every service in this repo.
UI: **https://logs.tkuipers.ca** (Authelia SSO; local admin at `/login?disableAutoLogin`).

## When something is broken

1. Open **Homelab overview** (Grafana home → *Overview* folder). It answers
   "what is down / failing / restarting right now": failing probes, workloads
   not ready, crash loops, restarts, ingress 5xx, firing alerts, failed Jobs,
   stale CronJobs, error-log spikes by service, node CPU/mem/disk.
2. Jump to the service's dashboard (*Services* dropdown at the top of every
   dashboard, or the list at the bottom of the overview). Every service has:
   - **Status**: ready replicas, restarts, error logs (1h), OOM kills,
     ingress 5xx ratio, **health check (in-cluster)** = the app's own health
     endpoint answers, **public URL reachable** = DNS+ingress+TLS+Authelia
     (behind Authelia this stops at the login redirect, so it does *not*
     prove the app works), TLS expiry. "no logs"/"no traffic"/"no pods" means
     exactly that - not zero.
   - **Failures**: logs by level, restarts, ingress status classes, the
     service's own access-log status codes, Kubernetes events by reason
   - **Traffic & latency** (if it has an ingress), **Resources** (CPU/mem vs
     request/limit, throttling) and **Logs** (level + regex filter variables,
     30 days, expand a line for every parsed field)
3. Dig into logs: *Explore* → Loki, or *Drilldown → Logs* (Logs Drilldown app).
   Fields parsed from the log line are structured metadata, so no parser is
   needed in queries:
   ```logql
   {k8s_namespace_name="mediacenter", service_name="sonarr"} | detected_level="error"
   {service_name="infrastructure-ingress-nginx-controller"} | status >= 500 | host="jellyfin.tkuipers.ca"
   {k8s_namespace_name="stocks"} | path="/api/orders" | status >= 400
   {service_name="kubernetes-events", k8s_namespace_name="stocks"} | type="Warning"
   ```
4. Traces: every request through ingress-nginx is a span in Tempo; ingress
   log lines carry `trace_id`, which links to the trace (Loki derived field).
5. Stocks: *Stocks - overview* has a **Pipeline activity** row (ingestion
   runs, decisions, JetStream consumer backlog/redeliveries, Postgres) -
   pods can be Ready while the pipeline is stuck.

## Pieces

| Component | Chart dir / ArgoCD app | What |
|-----------|------------------------|------|
| kube-prometheus-stack (release `kps`) | `helm-chart-kube-prometheus-stack` / `infrastructure-kube-prometheus-stack` | Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics, blackbox exporter (`probe=external`: every `*.tkuipers.ca` host, strict per class - `http_public` 2xx, `http_authelia` 302 to auth.tkuipers.ca, ...; `probe=internal`: each app's health endpoint / DB port via its Service, AdGuard LAN DNS via `dns_a`) |
| Loki | `helm-chart-loki` / `infrastructure-loki` | logs, single binary, filesystem; OTLP ingestion |
| Tempo | `helm-chart-tempo` / `infrastructure-tempo` | traces + span metrics/service graph |
| Alloy | `helm-chart-alloy` / `infrastructure-alloy` | DaemonSet: tails `/var/log/pods`, parses, ships to Loki; OTLP receiver (`alloy.observability.svc:4317/4318`). `alloy-events`: Kubernetes events → Loki |
| this dir (kustomize) | `infrastructure-observability` | namespace, storage, ServiceMonitors/PodMonitors, dashboards, alert rules, (ExternalSecrets) |

Exporters living next to the apps: exportarr (sonarr/radarr/readarr/prowlarr),
postgres-exporter (stocks, polymarket-bot), prometheus-nats-exporter (stocks,
JetStream lag), Jellyfin's built-in /metrics. Scrape configs:
`monitors/servicemonitors.yaml`.

### Log pipeline / parsing
`helm-chart-alloy/config/node.alloy` (collection, k8s metadata, export) and
`helm-chart-alloy/config/log-parsing.alloy` (the parsers). Every line ends up
with the message as the log line, `detected_level`, and the rest as fields:
JSON, logfmt, klog, nginx/uvicorn/combined/anki access logs (method, path,
status, latency, upstream, ...; level derived from status), *arr (NLog),
Jellyfin/Kavita (Serilog), Home Assistant/Python logging, sabnzbd, bazarr,
Postgres, MySQL, Redis, NATS, gluetun, zap console, Rust tracing, CoreDNS.
Anything else is kept raw with a best-effort level. Multi-line stack traces
are joined. `service_name` = owning workload; `log_format` says which parser hit.
Successful kubelet health checks (`GET /healthz` 2xx from the pod gateway /
kube-probe) are dropped; failing ones are kept. Access-log `path` has no
query string (`query` is its own field).

To change a parser: edit `log-parsing.alloy`, test locally with the alloy
binary against sample CRI files (`alloy run --stability.level=public-preview`),
push. Alloy hot-reloads the config.

### Storage / retention (~150 GB on dell-r620)
Cluster pattern: hostPath `/var/persist/observability-*` on dell-r620, wrapped
in static PVs (`storage-pvs.yaml`, class `observability-hostpath`).
Loki 100 Gi (60d retention; ~0.2-1 GB/day observed, budget alert), Prometheus 40 Gi
(`retentionSize: 36GB`, 90d), Tempo 8 Gi (5d), Grafana 2 Gi.
Pods writing to hostPath run as root (hostPath ignores fsGroup).

### Dashboards and alerts are generated
```
python3 tooling/observability/generate_dashboards.py   # -> dashboards/
python3 tooling/observability/generate_alerts.py       # -> alerts/
```
New service: add a `Svc(...)` line to `CATALOG` in the generator, re-run,
commit. Grafana's sidecar loads the ConfigMaps (label `grafana_dashboard`,
folder from annotation `grafana_folder`). Hand edits in the UI are not saved.

**Alerts** - two evaluators:
- *Grafana-managed* (folder *Alerts*, `generate_alerts.py`): every rule carries
  `namespace` + `service` labels and a `dashboard` annotation (the service
  dashboard, or the namespace's dashboards). Besides "is it up" (probes,
  replicas, crash loops) there are "is it failing" rules: *Error log spike*
  (sudden change vs yesterday) and *Errors logged steadily* (>20 errors/h for
  2h - catches things that are broken all the time), plus functional ones
  (stocks pipeline, JetStream, VPN tunnel, *arr health, backups via CronJob
  rules). Probe rules alert on *no data* too (blackbox exporter gone).
- *Prometheus* (kube-prometheus-stack default rules, routed by the kps
  Alertmanager): node/kubelet/apiserver/Prometheus internals, KubeJobNotCompleted
  etc. Rules that duplicate a Grafana rule are disabled in the kps values
  (`defaultRules.disabled`), and `GrafanaDown` / `GrafanaAlertingStalled` watch
  the Grafana evaluator. `Watchdog` always fires (dead-man's switch).

Noisy rule? Fix the level at the source or add a level correction in
`helm-chart-alloy/config/log-parsing.alloy` (section "level corrections") -
don't silence the rule.

**No contact point is configured yet** - alerts are visible in Grafana only.
To get paged, configure the same channel (ntfy / Pushover / Discord / email)
in **both** places: a Grafana contact point + notification policy, and a
receiver in the kps Alertmanager config (`alertmanager.config` in the kps
values); send `Watchdog` to a dead-man's switch (e.g. healthchecks.io) - the
whole stack runs on dell-r620, so that is the only way to hear about that
node dying.

### Verification
```
python3 tooling/observability/verify_log_coverage.py   # every container's logs are in Loki
python3 tooling/observability/verify_dashboards.py     # every dashboard panel returns data
```
(see the docstrings for the port-forwards / credentials they need)

### Databases in Grafana
Datasources *Stocks Postgres*, *Polymarket Postgres*, *Stock Guesser MySQL*
log in as `grafana_ro` (SELECT only, read-only transactions, 30s statement
timeout, 5 connections). Recreate the users after a database rebuild:
`tooling/scripts/setup-credentials/setup-grafana-db-readonly.sh`.

### Secrets
Grafana admin + OIDC client secret come from the 1Password item
"Observability Credentials" (Homelab vault) via ExternalSecrets (`secrets/`);
the OIDC client secret's argon2 hash is in the Authelia configmap (client
`grafana`). To rotate: `tooling/scripts/setup-credentials/setup-observability-credentials.sh --rotate`,
commit + push, then `... finalize`.

### Gotchas
- Loki only accepts lines up to ~1h older than the newest line of the same
  stream; Alloy exports with a single in-order consumer for that reason.
- Loki queriers only ask the ingester for the last 3h; data older than that
  shows up once its chunk is flushed (`POST /flush` on Loki forces it).
- Grafana 13 keeps dashboards in unified storage; the file provisioner's
  periodic poll logs "restricted database access" - the sidecar's reload API
  call is what applies dashboard changes.
- etcd and kube-proxy metrics are not scraped (Talos binds them to localhost).
- Talos machine/kernel logs (`dmesg`, kubelet, etcd) are not shipped; kernel
  OOM kills are only visible as `node_vmstat_oom_kill` (alerted).
- Loki logs "failed to load chunk ... no such file" when a query touches the original
  (non-backfill) streams for 2026-10-11 before ~06:04Z: stale index refs left by the
  migration's delete request. Harmless (that data was replaced by `log_origin=backfill-*`
  streams); they age out with retention. Alloy downgrades exactly that message to warn
  (`log-parsing.alloy`, marked TEMPORARY - remove after 2026-12-10).
- Alloy hot-reloads its config; one reload deadlocked it (no logs shipped).
  It now has a liveness probe, and "A node stopped shipping logs" alerts.
