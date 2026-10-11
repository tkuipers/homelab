#!/usr/bin/env python3
"""
Generate Grafana-managed alert rules (provisioned through the Grafana
sidecar, label grafana_alert=1).

    python3 tooling/observability/generate_alerts.py

Output: clusters/homelab/infrastructure/observability/alerts/

Two groups:
  * "Service monitors" - 1:1 ports of the monitors of the previous
    monitoring platform (see git history), as close as the data allows.
  * "Homelab" - generic incident alerts every service gets (probe down,
    5xx ratio, crash loops, error-log spikes, pipeline health, ...).

The kube-prometheus-stack default PrometheusRules (KubePodCrashLooping,
KubeJobFailed, NodeFilesystemSpaceFillingUp, ...) also show up in Grafana
under Alerting > Alert rules (data source managed).

Notifications (second key of the same ConfigMap): every alert goes to the
homelab agent (clusters/homelab/apps/homelab-agent), which investigates and
texts Tyler only when it needs him. Alerts about the agent itself (label
notify=relay, group "Homelab agent") go to its SMS relay instead, so they
arrive even when the agent is down. The webhook token comes from the env var
AGENT_WEBHOOK_TOKEN (Grafana interpolates $VARS in provisioning files).
"""
import os
import sys

import yaml

sys.path.insert(0, os.path.dirname(__file__))
from generate_dashboards import svc_uid  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "clusters/homelab/infrastructure/observability/alerts")


GRAFANA = "https://logs.tkuipers.ca"


def rule(uid, title, expr, op, threshold, for_="5m", ds="prometheus", severity="warning",
         summary="", description="", dashboard=None, window=600, no_data="OK", ns=None, svc=None,
         static_ns=None):
    """ns / svc: the query's label holding the namespace / service. Every rule
    gets normalised `namespace` and `service` labels (route/group by service
    regardless of which exporter the query uses) and a `dashboard` link: the
    given dashboard, else the namespace's dashboards (tag = namespace)."""
    q = {"refId": "A", "expr": expr, "instant": True, "intervalMs": 60000, "maxDataPoints": 43200}
    if ds == "loki":
        q = {"refId": "A", "expr": expr, "queryType": "instant", "intervalMs": 60000, "maxDataPoints": 43200}
    r = {
        "uid": uid, "title": title, "condition": "C",
        "data": [
            {"refId": "A", "relativeTimeRange": {"from": window, "to": 0}, "datasourceUid": ds, "model": q},
            {"refId": "B", "relativeTimeRange": {"from": 0, "to": 0}, "datasourceUid": "__expr__",
             "model": {"refId": "B", "type": "reduce", "expression": "A", "reducer": "last",
                       "settings": {"mode": "dropNN"}}},
            {"refId": "C", "relativeTimeRange": {"from": 0, "to": 0}, "datasourceUid": "__expr__",
             "model": {"refId": "C", "type": "threshold", "expression": "B",
                       "conditions": [{"evaluator": {"type": op, "params": [threshold]}}]}},
        ],
        "noDataState": no_data, "execErrState": "Error", "for": for_,
        "labels": {"severity": severity, **_target_labels(ns, svc, static_ns)},
        "annotations": {"summary": summary or title, "description": description},
        "isPaused": False,
    }
    if dashboard:
        # (__dashboardUid__ would also need __panelId__; a plain link is enough)
        r["annotations"]["dashboard"] = f"{GRAFANA}/d/{dashboard}"
    elif ns or static_ns:
        nsv = static_ns or "{{ $labels.%s }}" % ns
        r["annotations"]["dashboard"] = f"{GRAFANA}/dashboards?tag={nsv}"
    return r


def _target_labels(ns, svc, static_ns):
    out = {}
    if static_ns:
        out["namespace"] = static_ns
    elif ns:
        out["namespace"] = "{{ $labels.%s }}" % ns
    if svc:
        # svc may be a ready-made template (e.g. derived from a pod name)
        out["service"] = svc if "{{" in svc else "{{ $labels.%s }}" % svc
    return out


def deploy_down(uid, title, ns, deploy):
    dash = svc_uid(ns, deploy)
    return rule(uid, title,
                f'sum(kube_deployment_status_replicas_available{{namespace="{ns}", deployment="{deploy}"}})',
                "lt", 1, severity="critical", dashboard=dash, no_data="Alerting", static_ns=ns,
                summary=f"{ns}/{deploy} has no available replicas",
                description="Check the service dashboard (Kubernetes events + logs rows) for why pods are not ready.")


POD_TO_SERVICE = '{{ reReplaceAll "(-[a-z0-9]{8,10})?-[a-z0-9]{5}$|-[0-9]+$" "" $labels.pod }}'

SERVICE_MONITORS = [
    deploy_down("dd-homepage-pod-health", "Homepage pod health", "homepage", "homepage"),
    rule("dd-homepage-http-errors", "Homepage HTTP 5xx rate",
         '100 * (sum(rate(nginx_ingress_controller_requests{exported_namespace="homepage", status=~"5.."}[5m])) or vector(0)) / (sum(rate(nginx_ingress_controller_requests{exported_namespace="homepage"}[5m])) > 0)',
         "gt", 10, severity="critical", dashboard=svc_uid("homepage", "homepage"), static_ns="homepage",
         summary="More than 10% of homepage requests return 5xx",
         description="Ported monitor: nginx 5xx / total * 100 > 10 over 5m. Source is now the ingress-nginx metrics."),
    deploy_down("dd-argocd-server-health", "Argo CD server health", "argocd", "argocd-server"),
    rule("dd-argocd-sync-failures", "Argo CD apps out of sync",
         'count(argocd_app_info{sync_status="OutOfSync"}) or vector(0)', "gt", 2, for_="10m",
         dashboard=svc_uid("argocd", "argocd-server"), static_ns="argocd",
         summary="More than 2 Argo CD applications are OutOfSync for 10m",
         description="Ported monitor (critical > 2, warning > 1). See Argo CD dashboard > 'Applications not Synced/Healthy'."),
    deploy_down("dd-ingress-nginx-health", "Ingress NGINX health", "ingress-nginx", "infrastructure-ingress-nginx-controller"),
    deploy_down("dd-cert-manager-health", "cert-manager health", "cert-manager", "infrastructure-cert-manager"),
    deploy_down("dd-stock-guesser-pod-health", "Stock Guesser app pod health", "stock-guesser", "stock-guesser-app"),
    deploy_down("dd-stock-guesser-mysql-health", "Stock Guesser MySQL health", "stock-guesser", "mysql"),
    # The old monitor used APM (request duration > 10s). There is no tracing
    # in the app anymore; the closest signal is the readiness probe (it times
    # out when the app is slow/hung).
    rule("dd-stock-guesser-latency", "Stock Guesser app slow / probes failing",
         'sum(increase(prober_probe_total{namespace="stock-guesser", pod=~"stock-guesser-app-.*", result!="successful"}[5m])) or vector(0)',
         "gt", 3, dashboard=svc_uid("stock-guesser", "stock-guesser-app"), static_ns="stock-guesser",
         summary="Stock Guesser app is failing its probes",
         description="Ported from the APM latency monitor (avg request duration > 10s). There is no APM anymore; probe failures/timeouts are the replacement signal."),
    rule("dd-stock-guesser-errors", "Stock Guesser app error rate",
         '100 * (sum(count_over_time({k8s_namespace_name="stock-guesser", service_name="stock-guesser-app"} | status >= 500 | path !~ "/(readyz|healthz|livez|health)/?" [5m])) or vector(0)) / sum(count_over_time({k8s_namespace_name="stock-guesser", service_name="stock-guesser-app"} | status != "" | path !~ "/(readyz|healthz|livez|health)/?" [5m]))',
         "gt", 20, ds="loki", dashboard=svc_uid("stock-guesser", "stock-guesser-app"), static_ns="stock-guesser",
         summary="More than 20% of Stock Guesser requests fail (5xx)",
         description="Ported from the APM error-rate monitor (errors/hits > 20%). Now computed from the app's access logs in Loki (probe/health requests excluded)."),
    rule("dd-stock-guesser-training-failures", "Stock Guesser training job failed",
         'sum(kube_job_status_failed{namespace="stock-guesser", job_name=~"stock-guesser-training-[0-9]+"} > 0 and on (namespace, job_name) (time() - kube_job_status_start_time < 86400)) or vector(0)',
         "gt", 0, for_="0s", dashboard=svc_uid("stock-guesser", "stock-guesser-training"), static_ns="stock-guesser",
         summary="A stock-guesser-training Job failed",
         description="Ported monitor (failed training Job within 1d)."),
]

HOMELAB = [
    rule("hl-health-check-failing", "Service health check failing",
         'min by (target_namespace, target_service, instance) (probe_success{probe="internal"})', "lt", 1, for_="3m", severity="critical",
         ns="target_namespace", svc="target_service", no_data="Alerting",
         summary="{{ $labels.target_namespace }}/{{ $labels.target_service }} does not answer its health check",
         description="In-cluster probe of the app itself ({{ $labels.instance }}) via its Service. Open the service dashboard: Kubernetes events, restarts and logs. No data = the blackbox exporter (observability/blackbox) is down."),
    rule("hl-public-url-down", "Public URL unreachable",
         'min by (target_namespace, target_service, instance) (probe_success{probe="external"})', "lt", 1, for_="5m", severity="critical",
         ns="target_namespace", svc="target_service", no_data="Alerting",
         summary="{{ $labels.instance }} is not reachable (DNS / ingress / TLS / Authelia)",
         description="The public hostname fails while the app's own health check may still pass - suspect DNS (adguard, external-dns, aws-ip-updater), ingress-nginx, cert-manager or Authelia. Each host must answer like its class (blackbox module): http_public = 2xx after redirects, http_authelia = 302 to auth.tkuipers.ca; a 404 usually means the Ingress is gone."),
    rule("hl-authelia-failed-logins", "Authelia: many failed logins",
         'sum(increase(authelia_authn{success="false"}[15m]))', "gt", 10, for_="0s", static_ns="authelia",
         summary="{{ $values.B }} failed Authelia logins in 15m",
         description="Brute force or a broken auth backend. Authelia dashboard > 'Failed logins / bans'."),
    rule("hl-ingress-5xx", "Ingress 5xx ratio high",
         '(sum by (exported_namespace, ingress) (rate(nginx_ingress_controller_requests{status=~"5.."}[10m])) / sum by (exported_namespace, ingress) (rate(nginx_ingress_controller_requests[10m]) > 0.01))',
         "gt", 0.10, for_="5m", ns="exported_namespace", svc="ingress",
         summary="{{ $labels.exported_namespace }}/{{ $labels.ingress }}: more than 10% 5xx",
         description="Ingress NGINX dashboard > 'Top 5xx paths' shows which paths fail; the service dashboard shows its logs."),
    rule("hl-crashloop", "Container crash looping",
         'max by (namespace, pod, container) (kube_pod_container_status_waiting_reason{reason=~"CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerConfigError"})',
         "gt", 0, for_="5m", severity="critical", ns="namespace", svc=POD_TO_SERVICE,
         summary="{{ $labels.namespace }}/{{ $labels.pod }} ({{ $labels.container }}) is crash looping"),
    rule("hl-oomkilled", "Container OOMKilled",
         'max by (namespace, pod, container) (kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}) * on (namespace, pod, container) group_left() (increase(kube_pod_container_status_restarts_total[15m]) > 0)',
         "gt", 0, for_="0s", ns="namespace", svc=POD_TO_SERVICE,
         summary="{{ $labels.namespace }}/{{ $labels.pod }} ({{ $labels.container }}) was OOM killed",
         description="Memory panel on the service dashboard shows usage vs limit."),
    rule("hl-error-log-spike", "Error log spike",
         '(sum by (k8s_namespace_name, service_name) (count_over_time({k8s_namespace_name=~".+", service_name!="kubernetes-events"} | detected_level=~"error|fatal|critical" [10m])) > 50) unless on (k8s_namespace_name, service_name) (3 * sum by (k8s_namespace_name, service_name) (count_over_time({k8s_namespace_name=~".+", service_name!="kubernetes-events"} | detected_level=~"error|fatal|critical" [10m] offset 1d)) >= sum by (k8s_namespace_name, service_name) (count_over_time({k8s_namespace_name=~".+", service_name!="kubernetes-events"} | detected_level=~"error|fatal|critical" [10m])))',
         "gt", 0, ds="loki", for_="15m", ns="k8s_namespace_name", svc="service_name",
         summary="{{ $labels.k8s_namespace_name }}/{{ $labels.service_name }} logged {{ $values.B }} errors in 10m (>3x the same time yesterday)",
         description="A sudden change. Steady failures are caught by 'Errors logged steadily'. Open the service dashboard > Logs and filter level=error."),
    rule("hl-error-log-sustained", "Errors logged steadily",
         'sum by (k8s_namespace_name, service_name) (count_over_time({k8s_namespace_name=~".+", service_name!="kubernetes-events"} | detected_level=~"error|fatal|critical" [1h]))',
         "gt", 20, ds="loki", for_="2h", ns="k8s_namespace_name", svc="service_name",
         summary="{{ $labels.k8s_namespace_name }}/{{ $labels.service_name }} has logged more than 20 errors an hour for 2h ({{ $values.B }} in the last hour)",
         description="Something is failing continuously (a dependency, credentials, a region block...) even though the pod looks healthy. Service dashboard > Logs, level=error. If the errors are expected noise, fix the level at the source or in helm-chart-alloy/config/log-parsing.alloy (level corrections) rather than silencing."),
    rule("hl-vpn-unhealthy", "VPN tunnel unhealthy",
         'sum by (k8s_namespace_name, service_name) (count_over_time({k8s_namespace_name=~".+"} | k8s_container_name="gluetun" |= "restarting VPN" [30m]))',
         "gt", 2, ds="loki", for_="15m", ns="k8s_namespace_name", svc="service_name",
         summary="{{ $labels.k8s_namespace_name }}/{{ $labels.service_name }}: gluetun restarted the VPN {{ $values.B }} times in 30m",
         description="The VPN tunnel fails its health check, so the app behind it has no working network although the pod is Ready. gluetun logs say why (DNS, auth, server)."),
    rule("hl-cert-expiring", "TLS certificate expiring",
         'min by (instance) ((probe_ssl_earliest_cert_expiry - time()) / 86400)', "lt", 14, for_="1h", static_ns="cert-manager",
         dashboard=svc_uid("cert-manager", "infrastructure-cert-manager"),
         summary="Certificate for {{ $labels.instance }} expires in < 14 days",
         description="cert-manager should renew at 30 days; check the cert-manager dashboard and its logs."),
    rule("hl-cronjob-stale", "CronJob missed its schedule",
         '((time() - max by (namespace, cronjob) (kube_cronjob_status_last_successful_time)) - 2 * (max by (namespace, cronjob) (kube_cronjob_next_schedule_time) - max by (namespace, cronjob) (kube_cronjob_status_last_schedule_time)) - 1800) unless on (namespace, cronjob) (kube_cronjob_spec_suspend == 1)',
         "gt", 0, for_="10m", ns="namespace", svc="cronjob",
         summary="{{ $labels.namespace }}/{{ $labels.cronjob }}: no successful run for more than two schedule intervals",
         description="Value = seconds overdue. Check the CronJob dashboard (last success, failed jobs, logs)."),
    rule("hl-cronjob-never-succeeded", "CronJob has never succeeded",
         '(max by (namespace, cronjob) (kube_cronjob_info) unless on (namespace, cronjob) kube_cronjob_status_last_successful_time) and on (namespace, cronjob) (time() - kube_cronjob_created > 2 * 86400)',
         "gt", 0, for_="1h", ns="namespace", svc="cronjob",
         summary="{{ $labels.namespace }}/{{ $labels.cronjob }} exists for >2 days and never completed successfully"),
    rule("hl-job-failed", "Job failed",
         'max by (namespace, job_name) (kube_job_status_failed > 0) and on (namespace, job_name) (time() - kube_job_status_start_time < 86400)',
         "gt", 0, for_="0s", ns="namespace", svc='{{ reReplaceAll "-[0-9]+$" "" $labels.job_name }}',
         summary="Job {{ $labels.namespace }}/{{ $labels.job_name }} failed (started in the last 24h)",
         description="Logs of the job pod are in Loki even after the pod is gone: {k8s_namespace_name=\"{{ $labels.namespace }}\"} |= \"\" with k8s_pod_name=~\"{{ $labels.job_name }}-.*\"."),
    rule("hl-workload-unavailable", "Deployment has unavailable replicas",
         'max by (namespace, deployment) (kube_deployment_status_replicas_unavailable)', "gt", 0, for_="15m", ns="namespace", svc="deployment",
         summary="{{ $labels.namespace }}/{{ $labels.deployment }} has unavailable replicas for 15m"),
    rule("hl-daemonset-not-ready", "DaemonSet pods not ready",
         'max by (namespace, daemonset) (kube_daemonset_status_desired_number_scheduled - kube_daemonset_status_number_ready)', "gt", 0, for_="15m", ns="namespace", svc="daemonset",
         summary="{{ $labels.namespace }}/{{ $labels.daemonset }}: {{ $values.B }} pod(s) not ready (alloy = a node is not shipping logs)"),
    rule("hl-statefulset-not-ready", "StatefulSet replicas not ready",
         'max by (namespace, statefulset) (kube_statefulset_replicas - kube_statefulset_status_replicas_ready)', "gt", 0, for_="15m", severity="critical", ns="namespace", svc="statefulset",
         summary="{{ $labels.namespace }}/{{ $labels.statefulset }} has replicas not ready (Loki/Prometheus/Tempo/Alertmanager/Argo CD controller)"),
    rule("hl-node-disk-forecast", "Node filesystem will fill within 24h",
         'min by (instance, mountpoint) (predict_linear(node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs"}[6h], 86400))', "lt", 0, for_="30m", severity="critical", dashboard=svc_uid("observability", "kps-prometheus-node-exporter"), static_ns="kube-system",
         summary="{{ $labels.instance }} {{ $labels.mountpoint }} will be full within a day at the current rate",
         description="dell-r620 /var holds media, Loki, Prometheus and containerd; kubelet starts evicting at ~90%."),
    rule("hl-kernel-oom", "Kernel OOM kill on node",
         'sum by (instance) (increase(node_vmstat_oom_kill[15m]))', "gt", 0, for_="0s", dashboard=svc_uid("observability", "kps-prometheus-node-exporter"), static_ns="kube-system",
         summary="The kernel OOM-killed a process on {{ $labels.instance }}",
         description="Also catches child processes (e.g. ffmpeg) that container OOM metrics miss. Check node memory and the restarts on the overview."),
    rule("hl-cert-not-ready", "cert-manager certificate not ready",
         'max by (exported_namespace, name) (certmanager_certificate_ready_status{condition="False"})', "gt", 0, for_="1h", ns="exported_namespace",
         summary="Certificate {{ $labels.exported_namespace }}/{{ $labels.name }} is not Ready"),
    rule("hl-cert-expiring-cm", "cert-manager certificate expiring",
         'min by (exported_namespace, name) ((certmanager_certificate_expiration_timestamp_seconds - time()) / 86400)', "lt", 21, for_="1h", ns="exported_namespace",
         summary="Certificate {{ $labels.exported_namespace }}/{{ $labels.name }} expires in {{ $values.B }} days (renewal should have happened at 30d)"),
    rule("hl-postgres-down", "Postgres down",
         'min by (namespace) (pg_up)', "lt", 1, for_="3m", severity="critical", ns="namespace", svc='postgres',
         no_data="Alerting",
         summary="Postgres in {{ $labels.namespace }} is not answering the exporter"),
    rule("hl-stocks-ingestion-stalled", "Stocks ingestion stalled",
         'sum(count_over_time({k8s_namespace_name="stocks", service_name="ingestion"} |= "pipeline_complete" [3h]))', "lt", 1, ds="loki", for_="15m", no_data="Alerting", static_ns="stocks", svc="{{ \"ingestion\" }}",
         summary="Stocks ingestion has not completed a pipeline run in 3h (normally hourly)",
         description="Stocks overview > Pipeline activity. Ingestion logs (geo_risk_*_failed etc.) usually say why."),
    rule("hl-stocks-decisions-stalled", "Stocks decisions stalled",
         'sum(count_over_time({k8s_namespace_name="stocks", service_name="decision"} |= "decision.predicted" [26h]))', "lt", 1, ds="loki", for_="30m", no_data="Alerting", static_ns="stocks", svc="{{ \"decision\" }}",
         summary="The stocks decision service made no prediction in 26h"),
    rule("hl-jetstream-backlog", "NATS JetStream consumer backlog",
         'max by (stream_name, consumer_name) (jetstream_consumer_num_pending)', "gt", 500, for_="30m", static_ns="stocks",
         summary="{{ $labels.consumer_name }} on stream {{ $labels.stream_name }} has {{ $values.B }} unprocessed messages",
         description="The consumer is down or stuck - check the service that owns it (stocks overview > Pipeline activity)."),
    rule("hl-jetstream-redeliveries", "NATS JetStream redeliveries",
         'sum by (stream_name, consumer_name) (increase(jetstream_consumer_num_redelivered[30m]))', "gt", 20, for_="0s", static_ns="stocks",
         summary="{{ $labels.consumer_name }} keeps failing to ack messages on {{ $labels.stream_name }}"),
    rule("hl-node-disk", "Node filesystem almost full",
         'max by (instance, mountpoint) (1 - node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs"})',
         "gt", 0.85, for_="15m", severity="critical", dashboard=svc_uid("observability", "kps-prometheus-node-exporter"), static_ns="kube-system",
         summary="{{ $labels.instance }} {{ $labels.mountpoint }} is more than 85% full"),
    rule("hl-argocd-degraded", "Argo CD application degraded",
         'max by (name, health_status) (argocd_app_info{health_status=~"Degraded|Missing"})', "gt", 0, for_="15m", dashboard=svc_uid("argocd", "argocd-server"), static_ns="argocd",
         summary="Argo CD app {{ $labels.name }} is {{ $labels.health_status }}"),
    rule("hl-externalsecret-failing", "ExternalSecret not syncing",
         'max by (exported_namespace, name) (externalsecret_status_condition{condition="Ready", status="False"})', "gt", 0, for_="30m", ns="exported_namespace",
         summary="ExternalSecret {{ $labels.exported_namespace }}/{{ $labels.name }} is not Ready",
         description="Usually the 1Password item/field is missing. See the External Secrets Operator dashboard."),
    rule("hl-arr-health", "*arr health check failing",
         'max by (namespace, pod, source, message) ({__name__=~"(sonarr|radarr|readarr|prowlarr)_system_health_issues", source!="UpdateCheck"} > 0)',
         "gt", 0, for_="1h", ns="namespace", svc=POD_TO_SERVICE,
         summary="{{ $labels.pod }}: {{ $labels.message }}",
         description="The app's own health check (System > Status), check {{ $labels.source }}. 'Update available' notices are ignored."),
    # --- the observability pipeline itself -------------------------------
    rule("hl-logs-dropped", "Logs are being dropped",
         'sum(rate(otelcol_exporter_send_failed_log_records_total[10m])) or vector(0)', "gt", 1, for_="10m", severity="critical", static_ns="observability", dashboard=svc_uid("observability", "alloy"),
         summary="Alloy cannot ship logs to Loki", description="Check the Loki and Alloy dashboards (Observability folder)."),
    rule("hl-alloy-node-silent", "A node stopped shipping logs",
         'sum by (instance) (rate(otelcol_exporter_sent_log_records_total{component_id="otelcol.exporter.otlphttp.loki"}[10m]))', "lt", 0.01, for_="10m", severity="critical", static_ns="observability", dashboard=svc_uid("observability", "alloy"),
         summary="Alloy on {{ $labels.instance }} has not sent logs to Loki for 10m"),
    rule("hl-loki-discarding", "Loki is discarding log lines",
         'sum by (reason) (rate(loki_discarded_samples_total[10m]))', "gt", 0.1, for_="15m", static_ns="observability", dashboard=svc_uid("observability", "loki"),
         summary="Loki discards lines ({{ $labels.reason }}) - logs are being lost",
         description="too_far_behind = out-of-order delivery; rate_limited = raise limits in helm-chart-loki; line_too_long etc. Check the Loki dashboard."),
    rule("hl-scrape-down", "Prometheus target down",
         'count by (job, namespace) (up == 0)', "gt", 0, for_="15m", ns="namespace",
         summary="Scrape target {{ $labels.namespace }}/{{ $labels.job }} is down"),
    rule("hl-loki-storage-budget", "Loki storage budget at risk",
         'sum(rate(loki_ingester_chunk_stored_bytes_total[6h])) * 86400 * 60 / 1e9', "gt", 90, for_="1h", static_ns="observability", dashboard=svc_uid("observability", "loki"),
         summary="Loki would store ~{{ $values.B }} GB over its 60d retention (volume is 100Gi)",
         description="Find the noisy service on the Prometheus/observability dashboard ('Loki ingest by namespace') and lower its log level or drop the lines in Alloy, or lower retention_period in helm-chart-loki/values.yaml."),
    rule("hl-prometheus-tsdb-full", "Prometheus TSDB near its size limit",
         'max(prometheus_tsdb_storage_blocks_bytes + prometheus_tsdb_wal_storage_size_bytes) / 36e9', "gt", 0.95, for_="1h", static_ns="observability", dashboard=svc_uid("observability", "prometheus-kps"),
         summary="Prometheus storage is at its 36GB retentionSize (oldest data is being dropped early)"),
    rule("hl-loki-no-logs", "No logs arriving in Loki",
         'sum(count_over_time({k8s_namespace_name=~".+"} [10m]))', "lt", 1, ds="loki", for_="10m", severity="critical", static_ns="observability", dashboard=svc_uid("observability", "loki"),
         no_data="Alerting", summary="Loki has received no logs in 10 minutes"),
]


# Rules that were removed from this file. Grafana provisioning does not
# delete a rule just because it disappeared from the file.
def _relay(r):
    r["labels"]["notify"] = "relay"
    return r


# About the agent itself: texted by the relay, not handled by the agent.
AGENT = [
    _relay(deploy_down("agent-down", "Homelab agent down", "homelab-agent", "homelab-agent")),
    _relay(rule("agent-scan-overdue", "Homelab agent daily scan overdue",
                'time() - max(homelab_agent_last_scan_timestamp_seconds)', "gt", 30 * 3600, for_="30m",
                static_ns="homelab-agent", severity="warning",
                summary="The homelab agent's daily scan hasn't finished for {{ humanizeDuration $values.B.Value }}",
                description="Agent web UI: https://agent.tkuipers.ca (Claude signed in? runs stuck?)")),
]

AGENT_WEBHOOK = {"authorization_scheme": "Bearer", "authorization_credentials": "$AGENT_WEBHOOK_TOKEN", "httpMethod": "POST"}
NOTIFICATIONS = {
    "apiVersion": 1,
    "contactPoints": [
        {"orgId": 1, "name": "homelab-agent", "receivers": [
            {"uid": "homelab-agent", "type": "webhook", "disableResolveMessage": False,
             "settings": {"url": "http://homelab-agent.homelab-agent.svc/hooks/grafana", **AGENT_WEBHOOK}}]},
        {"orgId": 1, "name": "homelab-agent-relay", "receivers": [
            {"uid": "homelab-agent-relay", "type": "webhook", "disableResolveMessage": False,
             "settings": {"url": "http://homelab-agent-relay.homelab-agent.svc/hooks/grafana", **AGENT_WEBHOOK}}]},
    ],
    "policies": [{
        "orgId": 1, "receiver": "homelab-agent",
        "group_by": ["grafana_folder", "alertname"],
        "group_wait": "30s", "group_interval": "5m", "repeat_interval": "12h",
        "routes": [{"receiver": "homelab-agent-relay", "object_matchers": [["notify", "=", "relay"]], "repeat_interval": "6h"}],
    }],
}

RETIRED_UIDS = ["hl-probe-down"]


def _literal(dumper, data):
    if "\n" in data:
        return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="|")
    return dumper.represent_scalar("tag:yaml.org,2002:str", data)


def main():
    yaml.SafeDumper.add_representer(str, _literal)
    os.makedirs(OUT, exist_ok=True)
    doc = {
        "apiVersion": 1,
        "groups": [
            {"orgId": 1, "name": "Service monitors", "folder": "Alerts", "interval": "1m", "rules": SERVICE_MONITORS},
            {"orgId": 1, "name": "Homelab", "folder": "Alerts", "interval": "1m", "rules": HOMELAB},
            {"orgId": 1, "name": "Homelab agent", "folder": "Alerts", "interval": "1m", "rules": AGENT},
        ],
        "deleteRules": [{"orgId": 1, "uid": u} for u in RETIRED_UIDS],
    }
    body = yaml.safe_dump(doc, sort_keys=False, width=1000)
    cm = {
        "apiVersion": "v1", "kind": "ConfigMap",
        "metadata": {"name": "grafana-alert-rules", "namespace": "observability",
                     "labels": {"grafana_alert": "1"}},
        "data": {"homelab-alert-rules.yaml": body,
                 "homelab-notifications.yaml": yaml.safe_dump(NOTIFICATIONS, sort_keys=False, width=1000)},
    }
    with open(os.path.join(OUT, "alert-rules.yaml"), "w") as fh:
        fh.write("# GENERATED by tooling/observability/generate_alerts.py - do not edit by hand\n")
        yaml.safe_dump(cm, fh, sort_keys=False, width=1000)
    print(f"wrote {len(SERVICE_MONITORS) + len(HOMELAB) + len(AGENT)} rules + notification policy")


if __name__ == "__main__":
    main()
