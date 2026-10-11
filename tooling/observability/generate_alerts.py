#!/usr/bin/env python3
"""
Generate Grafana-managed alert rules (provisioned through the Grafana
sidecar, label grafana_alert=1).

    python3 tooling/observability/generate_alerts.py

Output: clusters/homelab/infrastructure/observability/alerts/

Two groups:
  * "Ported from Datadog" - 1:1 ports of the monitors that lived in
    infrastructure/datadog (see git history), as close as the data allows.
  * "Homelab" - generic incident alerts every service gets (probe down,
    5xx ratio, crash loops, error-log spikes, pipeline health, ...).

The kube-prometheus-stack default PrometheusRules (KubePodCrashLooping,
KubeJobFailed, NodeFilesystemSpaceFillingUp, ...) also show up in Grafana
under Alerting > Alert rules (data source managed).

No contact point is configured yet: alerts are visible in Grafana only.
"""
import os
import sys

import yaml

sys.path.insert(0, os.path.dirname(__file__))
from generate_dashboards import svc_uid  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "clusters/homelab/infrastructure/observability/alerts")


def rule(uid, title, expr, op, threshold, for_="5m", ds="prometheus", severity="warning",
         summary="", description="", dashboard=None, window=600, no_data="OK"):
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
        "labels": {"severity": severity},
        "annotations": {"summary": summary or title, "description": description},
        "isPaused": False,
    }
    if dashboard:
        # (__dashboardUid__ would also need __panelId__; a plain link is enough)
        r["annotations"]["dashboard"] = f"https://logs.tkuipers.ca/d/{dashboard}"
    return r


def deploy_down(uid, title, ns, deploy):
    dash = svc_uid(ns, deploy)
    return rule(uid, title,
                f'sum(kube_deployment_status_replicas_available{{namespace="{ns}", deployment="{deploy}"}})',
                "lt", 1, severity="critical", dashboard=dash, no_data="Alerting",
                summary=f"{ns}/{deploy} has no available replicas",
                description="Check the service dashboard (Kubernetes events + logs rows) for why pods are not ready.")


DATADOG_PORTS = [
    deploy_down("dd-homepage-pod-health", "Homepage pod health", "homepage", "homepage"),
    rule("dd-homepage-http-errors", "Homepage HTTP 5xx rate",
         '100 * (sum(rate(nginx_ingress_controller_requests{exported_namespace="homepage", status=~"5.."}[5m])) or vector(0)) / (sum(rate(nginx_ingress_controller_requests{exported_namespace="homepage"}[5m])) > 0)',
         "gt", 10, severity="critical", dashboard=svc_uid("homepage", "homepage"),
         summary="More than 10% of homepage requests return 5xx",
         description="Datadog port: nginx 5xx / total * 100 > 10 over 5m. Source is now the ingress-nginx metrics."),
    deploy_down("dd-argocd-server-health", "Argo CD server health", "argocd", "argocd-server"),
    rule("dd-argocd-sync-failures", "Argo CD apps out of sync",
         'count(argocd_app_info{sync_status="OutOfSync"}) or vector(0)', "gt", 2, for_="10m",
         dashboard=svc_uid("argocd", "argocd-server"),
         summary="More than 2 Argo CD applications are OutOfSync for 10m",
         description="Datadog port (critical > 2, warning > 1). See Argo CD dashboard > 'Applications not Synced/Healthy'."),
    deploy_down("dd-ingress-nginx-health", "Ingress NGINX health", "ingress-nginx", "infrastructure-ingress-nginx-controller"),
    deploy_down("dd-cert-manager-health", "cert-manager health", "cert-manager", "infrastructure-cert-manager"),
    deploy_down("dd-stock-guesser-pod-health", "Stock Guesser app pod health", "stock-guesser", "stock-guesser-app"),
    deploy_down("dd-stock-guesser-mysql-health", "Stock Guesser MySQL health", "stock-guesser", "mysql"),
    # Datadog used APM (trace.fastapi.request.duration > 10s). There is no
    # tracing in the app anymore; the closest signal is the readiness probe
    # (it times out when the app is slow/hung).
    rule("dd-stock-guesser-latency", "Stock Guesser app slow / probes failing",
         'sum(increase(prober_probe_total{namespace="stock-guesser", pod=~"stock-guesser-app-.*", result!="successful"}[5m])) or vector(0)',
         "gt", 3, dashboard=svc_uid("stock-guesser", "stock-guesser-app"),
         summary="Stock Guesser app is failing its probes",
         description="Datadog port of stock-guesser-latency (APM avg request duration > 10s). APM is gone; probe failures/timeouts are the replacement signal."),
    rule("dd-stock-guesser-errors", "Stock Guesser app error rate",
         '100 * (sum(count_over_time({k8s_namespace_name="stock-guesser", service_name="stock-guesser-app"} | status >= 500 [5m])) or vector(0)) / sum(count_over_time({k8s_namespace_name="stock-guesser", service_name="stock-guesser-app"} | status != "" [5m]))',
         "gt", 20, ds="loki", dashboard=svc_uid("stock-guesser", "stock-guesser-app"),
         summary="More than 20% of Stock Guesser requests fail (5xx)",
         description="Datadog port of stock-guesser-errors (APM errors/hits > 20%). Now computed from the app's access logs in Loki."),
    rule("dd-stock-guesser-training-failures", "Stock Guesser training job failed",
         'sum(kube_job_status_failed{namespace="stock-guesser", job_name=~"stock-guesser-training-[0-9]+"}) or vector(0)',
         "gt", 0, for_="0s", dashboard=svc_uid("stock-guesser", "stock-guesser-training"),
         summary="A stock-guesser-training Job failed",
         description="Datadog port (kubernetes_state.job.failed for the training CronJob over 1d)."),
]

HOMELAB = [
    rule("hl-probe-down", "Public endpoint down",
         'min by (target_namespace, target_service, instance) (probe_success)', "lt", 1, for_="3m", severity="critical",
         summary="{{ $labels.instance }} is not reachable from the cluster",
         description="Blackbox HTTPS probe (DNS + ingress + TLS + Authelia) failing. Open the service dashboard for {{ $labels.target_namespace }}/{{ $labels.target_service }}."),
    rule("hl-ingress-5xx", "Ingress 5xx ratio high",
         '(sum by (exported_namespace, ingress) (rate(nginx_ingress_controller_requests{status=~"5.."}[10m])) / sum by (exported_namespace, ingress) (rate(nginx_ingress_controller_requests[10m]) > 0.01))',
         "gt", 0.10, for_="5m",
         summary="{{ $labels.exported_namespace }}/{{ $labels.ingress }}: more than 10% 5xx",
         description="Ingress NGINX dashboard > 'Top 5xx paths' shows which paths fail; the service dashboard shows its logs."),
    rule("hl-crashloop", "Container crash looping",
         'max by (namespace, pod, container) (kube_pod_container_status_waiting_reason{reason=~"CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerConfigError"})',
         "gt", 0, for_="5m", severity="critical",
         summary="{{ $labels.namespace }}/{{ $labels.pod }} ({{ $labels.container }}) is crash looping"),
    rule("hl-oomkilled", "Container OOMKilled",
         'max by (namespace, pod, container) (kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}) * on (namespace, pod, container) group_left() (increase(kube_pod_container_status_restarts_total[15m]) > 0)',
         "gt", 0, for_="0s",
         summary="{{ $labels.namespace }}/{{ $labels.pod }} ({{ $labels.container }}) was OOM killed",
         description="Memory panel on the service dashboard shows usage vs limit."),
    rule("hl-error-log-spike", "Error log spike",
         'sum by (k8s_namespace_name, service_name) (count_over_time({k8s_namespace_name=~".+", service_name!="kubernetes-events"} | detected_level=~"error|fatal|critical" [10m]))',
         "gt", 100, ds="loki", for_="10m",
         summary="{{ $labels.k8s_namespace_name }}/{{ $labels.service_name }} logged >100 errors in 10m",
         description="Open the service dashboard > Logs and filter level=error."),
    rule("hl-cert-expiring", "TLS certificate expiring",
         'min by (instance) ((probe_ssl_earliest_cert_expiry - time()) / 86400)', "lt", 14, for_="1h",
         summary="Certificate for {{ $labels.instance }} expires in < 14 days",
         description="cert-manager should renew at 30 days; check the cert-manager dashboard and its logs."),
    rule("hl-cronjob-stale", "CronJob has not succeeded recently",
         '(time() - max by (namespace, cronjob) (kube_cronjob_status_last_successful_time)) / 3600', "gt", 50, for_="30m",
         summary="{{ $labels.namespace }}/{{ $labels.cronjob }}: no successful run for > 50h",
         description="All homelab CronJobs run at least daily. Check the CronJob dashboard and failed Jobs on the overview."),
    rule("hl-workload-unavailable", "Deployment has unavailable replicas",
         'max by (namespace, deployment) (kube_deployment_status_replicas_unavailable)', "gt", 0, for_="15m",
         summary="{{ $labels.namespace }}/{{ $labels.deployment }} has unavailable replicas for 15m"),
    rule("hl-node-disk", "Node filesystem almost full",
         'max by (instance, mountpoint) (1 - node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs"})',
         "gt", 0.85, for_="15m", severity="critical",
         summary="{{ $labels.instance }} {{ $labels.mountpoint }} is more than 85% full"),
    rule("hl-argocd-degraded", "Argo CD application degraded",
         'max by (name, health_status) (argocd_app_info{health_status=~"Degraded|Missing"})', "gt", 0, for_="15m",
         summary="Argo CD app {{ $labels.name }} is {{ $labels.health_status }}"),
    rule("hl-externalsecret-failing", "ExternalSecret not syncing",
         'max by (exported_namespace, name) (externalsecret_status_condition{condition="Ready", status="False"})', "gt", 0, for_="30m",
         summary="ExternalSecret {{ $labels.exported_namespace }}/{{ $labels.name }} is not Ready",
         description="Usually the 1Password item/field is missing. See the External Secrets Operator dashboard."),
    rule("hl-arr-health", "*arr health check failing",
         'max by (job) (sonarr_system_health_issues or radarr_system_health_issues or readarr_system_health_issues or prowlarr_system_health_issues)',
         "gt", 0, for_="1h",
         summary="{{ $labels.job }} reports health issues (System > Status)"),
    # --- the observability pipeline itself -------------------------------
    rule("hl-logs-dropped", "Logs are being dropped",
         'sum(rate(otelcol_exporter_send_failed_log_records_total[10m])) or vector(0)', "gt", 1, for_="10m", severity="critical",
         summary="Alloy cannot ship logs to Loki", description="Check the Loki and Alloy dashboards (Observability folder)."),
    rule("hl-scrape-down", "Prometheus target down",
         'count by (job, namespace) (up == 0)', "gt", 0, for_="15m",
         summary="Scrape target {{ $labels.namespace }}/{{ $labels.job }} is down"),
    rule("hl-loki-storage-budget", "Loki storage budget at risk",
         'sum(rate(loki_ingester_chunk_stored_bytes_total[6h])) * 86400 * 60 / 1e9', "gt", 90, for_="1h",
         summary="Loki would store ~{{ $values.B }} GB over its 60d retention (volume is 100Gi)",
         description="Find the noisy service on the Prometheus/observability dashboard ('Loki ingest by namespace') and lower its log level or drop the lines in Alloy, or lower retention_period in helm-chart-loki/values.yaml."),
    rule("hl-prometheus-tsdb-full", "Prometheus TSDB near its size limit",
         'max(prometheus_tsdb_storage_blocks_bytes + prometheus_tsdb_wal_storage_size_bytes) / 36e9', "gt", 0.95, for_="1h",
         summary="Prometheus storage is at its 36GB retentionSize (oldest data is being dropped early)"),
    rule("hl-loki-no-logs", "No logs arriving in Loki",
         'sum(count_over_time({k8s_namespace_name=~".+"} [10m]))', "lt", 1, ds="loki", for_="10m", severity="critical",
         no_data="Alerting", summary="Loki has received no logs in 10 minutes"),
]


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
            {"orgId": 1, "name": "Ported from Datadog", "folder": "Alerts", "interval": "1m", "rules": DATADOG_PORTS},
            {"orgId": 1, "name": "Homelab", "folder": "Alerts", "interval": "1m", "rules": HOMELAB},
        ],
    }
    body = yaml.safe_dump(doc, sort_keys=False, width=1000)
    cm = {
        "apiVersion": "v1", "kind": "ConfigMap",
        "metadata": {"name": "grafana-alert-rules", "namespace": "observability",
                     "labels": {"grafana_alert": "1"}},
        "data": {"homelab-alert-rules.yaml": body},
    }
    with open(os.path.join(OUT, "alert-rules.yaml"), "w") as fh:
        fh.write("# GENERATED by tooling/observability/generate_alerts.py - do not edit by hand\n")
        yaml.safe_dump(cm, fh, sort_keys=False, width=1000)
    print(f"wrote {len(DATADOG_PORTS) + len(HOMELAB)} rules")


if __name__ == "__main__":
    main()
