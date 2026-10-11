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
     ingress 5xx ratio, external probe (DNS+ingress+TLS+Authelia), TLS expiry
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

## Pieces

| Component | Chart dir / ArgoCD app | What |
|-----------|------------------------|------|
| kube-prometheus-stack (release `kps`) | `helm-chart-kube-prometheus-stack` / `infrastructure-kube-prometheus-stack` | Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics, blackbox exporter (probes of every `*.tkuipers.ca` host) |
| Loki | `helm-chart-loki` / `infrastructure-loki` | logs, single binary, filesystem; OTLP ingestion |
| Tempo | `helm-chart-tempo` / `infrastructure-tempo` | traces + span metrics/service graph |
| Alloy | `helm-chart-alloy` / `infrastructure-alloy` | DaemonSet: tails `/var/log/pods`, parses, ships to Loki; OTLP receiver (`alloy.observability.svc:4317/4318`). `alloy-events`: Kubernetes events → Loki |
| this dir (kustomize) | `infrastructure-observability` | namespace, storage, ServiceMonitors/PodMonitors, dashboards, alert rules, (ExternalSecrets) |

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

To change a parser: edit `log-parsing.alloy`, test locally with the alloy
binary against sample CRI files (`alloy run --stability.level=public-preview`),
push. Alloy hot-reloads the config.

### Storage / retention (~150 GB on dell-r620)
Cluster pattern: hostPath `/var/persist/observability-*` on dell-r620, wrapped
in static PVs (`storage-pvs.yaml`, class `observability-hostpath`).
Loki 100 Gi (30d retention; ~1 GB/day observed), Prometheus 40 Gi
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
Alert rules are Grafana-managed (folder *Alerts*); the kube-prometheus-stack
default rules appear next to them. **No contact point is configured yet** -
alerts are visible in Grafana only.

### Verification
```
python3 tooling/observability/verify_log_coverage.py   # every container's logs are in Loki
python3 tooling/observability/verify_dashboards.py     # every dashboard panel returns data
```
(see the docstrings for the port-forwards / credentials they need)

### Secrets
Grafana admin + OIDC client secret currently live in hand-made Secrets
(`kubectl -n observability get secret -l temp-secret=true`).
`tooling/scripts/setup-credentials/setup-observability-credentials.sh` moves
them to 1Password and switches to ExternalSecrets (`secrets/`).

### Gotchas
- Loki only accepts lines up to ~1h older than the newest line of the same
  stream; Alloy exports with a single in-order consumer for that reason.
- Loki queriers only ask the ingester for the last 3h; data older than that
  shows up once its chunk is flushed (`POST /flush` on Loki forces it).
- Grafana 13 keeps dashboards in unified storage; the file provisioner's
  periodic poll logs "restricted database access" - the sidecar's reload API
  call is what applies dashboard changes.
- etcd and kube-proxy metrics are not scraped (Talos binds them to localhost).
