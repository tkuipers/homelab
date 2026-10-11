#!/usr/bin/env python3
"""
Generate the Grafana dashboards for the homelab observability stack.

Every service in the repo gets a dashboard built from the same template
(health, failures, traffic, resources, logs) plus service specific panels.
Output goes to clusters/homelab/infrastructure/observability/dashboards/ as
JSON files + a kustomization that turns them into ConfigMaps the Grafana
sidecar picks up (label grafana_dashboard=1, annotation grafana_folder).

    python3 tooling/observability/generate_dashboards.py

Add a service: append a Svc(...) to CATALOG below and re-run.

Conventions / data sources
  - Prometheus (uid prometheus): kube-state-metrics, cAdvisor, ingress-nginx,
    blackbox probes, exporters.
  - Loki (uid loki): logs arrive via Alloy OTLP; stream labels are
    k8s_namespace_name, service_name (= owning workload), k8s_container_name,
    k8s_pod_name. Parsed fields (status, method, path, logger, ...) are
    structured metadata, level is detected_level.
"""
import hashlib
import json
import os
import re
from dataclasses import dataclass, field
from typing import Callable, List, Optional

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "clusters/homelab/infrastructure/observability/dashboards")

PROM = {"type": "prometheus", "uid": "prometheus"}
LOKI = {"type": "loki", "uid": "loki"}

KPS_VALUES = os.path.join(ROOT, "clusters/homelab/infrastructure/observability/helm-chart-kube-prometheus-stack/values.yaml")


def internal_probes():
    """(namespace, workload) pairs that have an in-cluster blackbox health probe."""
    import yaml
    v = yaml.safe_load(open(KPS_VALUES))
    out = set()
    for t in v["prometheus-blackbox-exporter"]["serviceMonitor"]["targets"]:
        r = t.get("additionalMetricsRelabels", {})
        if r.get("probe") == "internal":
            out.add((r["target_namespace"], r["target_service"]))
    return out


INTERNAL_PROBES = internal_probes()

LEVEL_COLORS = {
    "fatal": "dark-red", "critical": "dark-red", "error": "red", "warn": "orange",
    "info": "green", "debug": "blue", "trace": "purple", "unknown": "text",
}

# ----------------------------------------------------------------------------
# Catalog
# ----------------------------------------------------------------------------


@dataclass
class Svc:
    ns: str                     # namespace
    name: str                   # workload name (== Loki service_name)
    title: str                  # dashboard title
    kind: str = "deployment"    # deployment|statefulset|daemonset|cronjob|static
    folder: str = "Apps"
    ingress: List[str] = field(default_factory=list)   # ingress object names
    probe: Optional[str] = None                        # blackbox target_service
    access_logs: bool = False   # emits per-request access logs (status field)
    extras: List[Callable] = field(default_factory=list)
    description: str = ""
    quiet: bool = False         # logs very rarely: Logs panel looks back 400d (archive streams)


def pod_re(s: Svc) -> str:
    n = s.name
    return {
        "deployment": f"{n}-[a-z0-9]{{6,10}}-[a-z0-9]{{5}}",
        "statefulset": f"{n}-[0-9]+",
        "daemonset": f"{n}-[a-z0-9]{{5}}",
        "cronjob": f"{n}-[0-9]+-[a-z0-9]{{5}}",
        "static": f"{n}-.+",
    }[s.kind]


def loki_sel(s: Svc) -> str:
    return f'{{k8s_namespace_name="{s.ns}", service_name="{s.name}"}}'


def kpod(s: Svc) -> str:
    return f'namespace="{s.ns}", pod=~"{pod_re(s)}"'


# ----------------------------------------------------------------------------
# Panel builders
# ----------------------------------------------------------------------------

class Board:
    def __init__(self, uid, title, tags, folder, time_from="now-24h", description=""):
        self.uid, self.title, self.tags, self.folder = uid, title, tags, folder
        self.time_from, self.description = time_from, description
        self.panels, self.x, self.y, self.row_h, self.pid = [], 0, 0, 0, 1
        self.variables = []

    def _place(self, w, h):
        if self.x + w > 24:
            self.x, self.y = 0, self.y + self.row_h
            self.row_h = 0
        pos = {"x": self.x, "y": self.y, "w": w, "h": h}
        self.x += w
        self.row_h = max(self.row_h, h)
        return pos

    def _add(self, p, w, h):
        p["id"] = self.pid
        self.pid += 1
        p["gridPos"] = self._place(w, h)
        self.panels.append(p)
        return p

    def row(self, title):
        if self.x:
            self.x, self.y, self.row_h = 0, self.y + self.row_h, 0
        p = {"type": "row", "title": title, "collapsed": False, "panels": []}
        p["id"] = self.pid
        self.pid += 1
        p["gridPos"] = {"x": 0, "y": self.y, "w": 24, "h": 1}
        self.y += 1
        self.panels.append(p)

    def stat(self, title, expr, unit="short", ds=PROM, thresholds=None, w=4, h=4,
             mappings=None, desc="", decimals=None, legend="", no_value=None):
        steps = thresholds or [{"color": "green", "value": None}]
        if no_value:
            # "nothing to report" is shown as text instead of a misleading 0:
            # the query returns -1 when there is no data and a value mapping
            # renders it (the panel still has data, unlike Grafana's noValue)
            expr = f"({expr}) or " + ("(vector(0) - 1)" if ds is LOKI else "vector(-1)")
            mappings = (mappings or []) + [{"type": "value", "options": {"-1": {"text": no_value, "color": "text"}}}]
        p = {
            "type": "stat", "title": title, "description": desc, "datasource": ds,
            "targets": [target(ds, expr, legend=legend, instant=True)],
            "fieldConfig": {"defaults": {
                "unit": unit, "mappings": mappings or [],
                "thresholds": {"mode": "absolute", "steps": steps},
                "color": {"mode": "thresholds"},
                **({"decimals": decimals} if decimals is not None else {}),
            }, "overrides": []},
            "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                        "colorMode": "background", "graphMode": "none", "textMode": "auto",
                        "justifyMode": "center"},
        }
        return self._add(p, w, h)

    def ts(self, title, targets, unit="short", ds=PROM, w=12, h=8, stack=False,
           bars=False, desc="", overrides=None, min0=True):
        p = {
            "type": "timeseries", "title": title, "description": desc, "datasource": ds,
            "targets": [target(ds, e, legend=l, ref=chr(65 + i)) for i, (e, l) in enumerate(targets)],
            "fieldConfig": {"defaults": {
                "unit": unit,
                **({"min": 0} if min0 else {}),
                "custom": {
                    "drawStyle": "bars" if bars else "line",
                    "fillOpacity": 80 if bars else 10,
                    "lineWidth": 1, "showPoints": "never",
                    "stacking": {"mode": "normal" if stack else "none", "group": "A"},
                    "spanNulls": True,
                },
            }, "overrides": overrides or []},
            "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": True},
                        "tooltip": {"mode": "multi", "sort": "desc"}},
        }
        return self._add(p, w, h)

    def table(self, title, targets, w=12, h=8, ds=PROM, desc="", transformations=None, overrides=None):
        p = {
            "type": "table", "title": title, "description": desc, "datasource": ds,
            "targets": [target(ds, e, legend=l, ref=chr(65 + i), instant=True, fmt="table")
                        for i, (e, l) in enumerate(targets)],
            "fieldConfig": {"defaults": {}, "overrides": overrides or []},
            "options": {"showHeader": True, "cellHeight": "sm"},
            "transformations": transformations or [],
        }
        return self._add(p, w, h)

    def logs(self, title, expr, w=24, h=12, desc="", time_from=None, max_lines=500):
        p = {
            "type": "logs", "title": title, "description": desc, "datasource": LOKI,
            "targets": [{**target(LOKI, expr), "maxLines": max_lines}],
            "options": {"showTime": True, "wrapLogMessage": True, "sortOrder": "Descending",
                        "enableLogDetails": True, "prettifyLogMessage": False,
                        "dedupStrategy": "none", "showCommonLabels": False, "showLabels": False},
        }
        if time_from:
            p["timeFrom"] = time_from
        return self._add(p, w, h)

    def text(self, title, content, w=24, h=3):
        p = {"type": "text", "title": title, "options": {"mode": "markdown", "content": content}}
        return self._add(p, w, h)

    def dashlist(self, title, tag, w=24, h=10):
        p = {"type": "dashlist", "title": title,
             "options": {"showSearch": True, "showStarred": False, "showRecentlyViewed": False,
                         "showHeadings": True, "folderUID": "", "maxItems": 200, "tags": [tag],
                         "query": "", "includeVars": False, "keepTime": True}}
        return self._add(p, w, h)

    def alertlist(self, title, w=24, h=8):
        p = {"type": "alertlist", "title": title,
             "options": {"viewMode": "list", "groupMode": "default", "maxItems": 50,
                         "sortOrder": 1, "dashboardAlerts": False, "alertInstanceLabelFilter": "",
                         "stateFilter": {"firing": True, "pending": True, "noData": False,
                                         "normal": False, "error": True}}}
        return self._add(p, w, h)

    def add_level_search_vars(self):
        self.variables += [
            {"type": "custom", "name": "level", "label": "Log level",
             "query": "fatal,critical,error,warn,info,debug,trace,unknown",
             "multi": True, "includeAll": True, "allValue": ".*",
             "current": {"selected": True, "text": ["All"], "value": ["$__all"]}},
            {"type": "textbox", "name": "search", "label": "Search (regex)", "query": "",
             "current": {"text": "", "value": ""}},
        ]

    def render(self):
        return {
            "uid": self.uid, "title": self.title, "tags": self.tags, "description": self.description,
            "timezone": "browser", "editable": True, "graphTooltip": 1, "schemaVersion": 39,
            "refresh": "1m", "time": {"from": self.time_from, "to": "now"},
            "templating": {"list": self.variables},
            "links": [
                {"title": "Homelab overview", "type": "link", "url": "/d/homelab-overview",
                 "icon": "dashboard", "keepTime": True},
                {"title": "Services", "type": "dashboards", "tags": ["service"], "asDropdown": True,
                 "keepTime": True, "includeVars": False},
                {"title": "Explore logs", "type": "link", "url": "/a/grafana-lokiexplore-app/explore",
                 "icon": "doc", "targetBlank": True},
            ],
            "panels": self.panels,
        }


def target(ds, expr, legend="", ref="A", instant=False, fmt=None):
    t = {"datasource": ds, "refId": ref, "expr": expr}
    if ds is PROM:
        t.update({"legendFormat": legend or "__auto", "range": not instant, "instant": instant})
        if fmt:
            t["format"] = fmt
    else:
        t.update({"queryType": "instant" if instant else "range", "legendFormat": legend})
        if fmt:
            t["format"] = fmt
    return t


def level_overrides():
    return [{"matcher": {"id": "byName", "options": lvl},
             "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": c}}]}
            for lvl, c in LEVEL_COLORS.items()]


def status_overrides():
    cols = {"2xx": "green", "3xx": "blue", "4xx": "orange", "5xx": "red"}
    return [{"matcher": {"id": "byName", "options": k},
             "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": v}}]}
            for k, v in cols.items()]


RED_IF_ABOVE_0 = [{"color": "green", "value": None}, {"color": "red", "value": 1}]
ORANGE_RED = [{"color": "green", "value": None}, {"color": "orange", "value": 1}, {"color": "red", "value": 10}]
UPDOWN = [{"type": "value", "options": {"0": {"text": "DOWN", "color": "red"},
                                        "1": {"text": "UP", "color": "green"}}}]

# ----------------------------------------------------------------------------
# Standard service dashboard
# ----------------------------------------------------------------------------


def health_stat(b: Board, s: Svc):
    ns, n = s.ns, s.name
    pct = [{"color": "red", "value": None}, {"color": "orange", "value": 0.5}, {"color": "green", "value": 1}]
    if s.kind == "deployment":
        b.stat("Ready replicas", f'(sum(kube_deployment_status_replicas_available{{namespace="{ns}", deployment="{n}"}}) / (sum(kube_deployment_spec_replicas{{namespace="{ns}", deployment="{n}"}}) > 0)) or (sum(kube_deployment_spec_replicas{{namespace="{ns}", deployment="{n}"}}) * 0 - 1)',
               unit="percentunit", thresholds=pct, desc="available / desired replicas",
               mappings=[{"type": "value", "options": {"-1": {"text": "scaled to 0", "color": "blue"}}}])
    elif s.kind == "statefulset":
        b.stat("Ready replicas", f'sum(kube_statefulset_status_replicas_ready{{namespace="{ns}", statefulset="{n}"}}) / sum(kube_statefulset_replicas{{namespace="{ns}", statefulset="{n}"}})',
               unit="percentunit", thresholds=pct)
    elif s.kind == "daemonset":
        b.stat("Ready pods", f'sum(kube_daemonset_status_number_ready{{namespace="{ns}", daemonset="{n}"}}) / sum(kube_daemonset_status_desired_number_scheduled{{namespace="{ns}", daemonset="{n}"}})',
               unit="percentunit", thresholds=pct)
    elif s.kind == "static":
        b.stat("Ready", f'sum(kube_pod_status_ready{{namespace="{ns}", pod=~"{pod_re(s)}", condition="true"}})',
               thresholds=[{"color": "red", "value": None}, {"color": "green", "value": 1}])
    elif s.kind == "cronjob":
        b.stat("Since last success", f'time() - max(kube_cronjob_status_last_successful_time{{namespace="{ns}", cronjob="{n}"}})',
               unit="s", desc="time since the last successful run",
               thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 2 * 86400}, {"color": "red", "value": 7 * 86400}])
        b.stat("Failed jobs (kept history)", f'sum(kube_job_status_failed{{namespace="{ns}", job_name=~"{n}-[0-9]+"}}) or vector(0)',
               thresholds=RED_IF_ABOVE_0, desc="failed Jobs still present (history limit)")
        b.stat("Suspended", f'max(kube_cronjob_spec_suspend{{namespace="{ns}", cronjob="{n}"}})',
               mappings=[{"type": "value", "options": {"0": {"text": "no", "color": "green"}, "1": {"text": "SUSPENDED", "color": "orange"}}}])


def svc_uid(ns: str, name: str) -> str:
    uid = f"svc-{ns}-{name}"
    if len(uid) > 40:  # grafana uid limit
        uid = uid[:31] + "-" + hashlib.sha1(uid.encode()).hexdigest()[:8]
    return uid


def standard(s: Svc) -> Board:
    uid = svc_uid(s.ns, s.name)
    b = Board(uid, s.title, ["homelab", "service", s.ns], s.folder,
              time_from="now-7d" if s.kind == "cronjob" else "now-24h",
              description=s.description or f"{s.kind} {s.ns}/{s.name}")
    b.add_level_search_vars()
    sel = loki_sel(s)
    kp = kpod(s)

    # ---- status -----------------------------------------------------------
    b.row("Status")
    health_stat(b, s)
    b.stat("Restarts (24h)", f'sum(increase(kube_pod_container_status_restarts_total{{{kp}}}[24h]))',
           thresholds=ORANGE_RED, decimals=0, no_value="no pods")
    b.stat("Error logs (1h)", f'sum(count_over_time({sel} | detected_level=~"error|fatal|critical" [1h])) or (sum(count_over_time({sel} [1h])) * 0)',
           ds=LOKI, thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 1}, {"color": "red", "value": 50}],
           desc="log lines at error level or worse in the last hour ('no logs' = the service logged nothing at all)", no_value="no logs (1h)")
    b.stat("OOMKilled (last termination)", f'sum(kube_pod_container_status_last_terminated_reason{{{kp}, reason="OOMKilled"}}) or (count(kube_pod_container_info{{{kp}}}) * 0)',
           thresholds=RED_IF_ABOVE_0, desc="containers whose last termination was an OOM kill", no_value="no pods")
    if s.ingress:
        ing = "|".join(s.ingress)
        b.stat("Ingress 5xx (1h)",
               f'(sum(rate(nginx_ingress_controller_requests{{exported_namespace="{s.ns}", ingress=~"{ing}", status=~"5.."}}[1h])) or vector(0)) / (sum(rate(nginx_ingress_controller_requests{{exported_namespace="{s.ns}", ingress=~"{ing}"}}[1h])) > 0)',
               unit="percentunit", decimals=2, no_value="no traffic",
               thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 0.01}, {"color": "red", "value": 0.05}],
               desc="share of requests through the ingress answered with 5xx")
    if (s.ns, s.name) in INTERNAL_PROBES:
        b.stat("Health check (in-cluster)", f'min(probe_success{{probe="internal", target_namespace="{s.ns}", target_service="{s.name}"}})',
               mappings=UPDOWN, thresholds=[{"color": "red", "value": None}, {"color": "green", "value": 1}],
               desc="blackbox probe of the app's own health endpoint (or TCP port) through its Service - the app itself answers")
    if s.probe:
        b.stat("Public URL reachable", f'min(probe_success{{probe="external", target_namespace="{s.ns}", target_service="{s.probe}"}})',
               mappings=UPDOWN, thresholds=[{"color": "red", "value": None}, {"color": "green", "value": 1}],
               desc="HTTPS probe of the public hostname: DNS + ingress + TLS (+ Authelia). Behind Authelia this stops at the login redirect and does NOT prove the app works - see 'Health check (in-cluster)'")
        b.stat("TLS cert expires in", f'min(probe_ssl_earliest_cert_expiry{{probe="external", target_namespace="{s.ns}", target_service="{s.probe}"}} - time())',
               unit="s", thresholds=[{"color": "red", "value": None}, {"color": "orange", "value": 7 * 86400}, {"color": "green", "value": 21 * 86400}])

    # ---- failures ---------------------------------------------------------
    b.row("Failures")
    b.ts("Logs by level", [(f'sum by (detected_level) (count_over_time({sel} [$__auto])) or vector(0)', "{{detected_level}}")],
         ds=LOKI, bars=True, stack=True, overrides=level_overrides(),
         desc="log lines per interval, split by detected level")
    b.ts("Container restarts", [(f'sum by (container) (increase(kube_pod_container_status_restarts_total{{{kp}}}[10m])) or vector(0)', "{{container}}")],
         bars=True, desc="restarts per 10m window")
    if s.ingress:
        ing = "|".join(s.ingress)
        b.ts("Ingress responses by status class",
             [(f'sum by (status_class) (label_replace(rate(nginx_ingress_controller_requests{{exported_namespace="{s.ns}", ingress=~"{ing}"}}[$__rate_interval]), "status_class", "${{1}}xx", "status", "(.)..")) or vector(0)', "{{status_class}}")],
             unit="reqps", stack=True, overrides=status_overrides())
    if s.access_logs:
        b.ts("Responses by status (access logs)",
             [(f'sum by (status) (count_over_time({sel} | status=~".+" [$__auto]))', "{{status}}")],
             ds=LOKI, bars=True, stack=True,
             desc="per-request access log lines emitted by the service itself (includes internal traffic and health checks)")
    b.ts("Kubernetes events by reason", [(f'sum by (type, reason) (count_over_time({{service_name="kubernetes-events", k8s_namespace_name="{s.ns}"}} | name=~"{s.name}.*" [$__auto])) or vector(0)', "{{type}} {{reason}}")],
         ds=LOKI, bars=True, stack=True, w=12 if not (s.ingress or s.access_logs) else 24,
         desc="Kubernetes events for this workload's objects (Warning = BackOff, Unhealthy, FailedScheduling, ...). The raw events are in the namespace overview and in Explore: {service_name=\"kubernetes-events\"}")

    # ---- traffic ----------------------------------------------------------
    if s.ingress:
        ing = "|".join(s.ingress)
        b.row("Traffic & latency (ingress)")
        b.ts("Requests / s", [(f'sum by (host) (rate(nginx_ingress_controller_requests{{exported_namespace="{s.ns}", ingress=~"{ing}"}}[$__rate_interval])) or vector(0)', "{{host}}")],
             unit="reqps", w=8)
        b.ts("Latency (ingress -> response)", [
            (f'histogram_quantile(0.5, sum by (le) (rate(nginx_ingress_controller_request_duration_seconds_bucket{{exported_namespace="{s.ns}", ingress=~"{ing}"}}[$__rate_interval])))', "p50"),
            (f'histogram_quantile(0.95, sum by (le) (rate(nginx_ingress_controller_request_duration_seconds_bucket{{exported_namespace="{s.ns}", ingress=~"{ing}"}}[$__rate_interval])))', "p95"),
            (f'histogram_quantile(0.99, sum by (le) (rate(nginx_ingress_controller_request_duration_seconds_bucket{{exported_namespace="{s.ns}", ingress=~"{ing}"}}[$__rate_interval])))', "p99"),
        ] + ([(f'max(probe_duration_seconds{{probe="external", target_namespace="{s.ns}", target_service="{s.probe}"}})', "external probe (end-to-end)")] if s.probe else []),
             unit="s", w=8, desc="ingress request duration percentiles (requests stopped by Authelia have none) and the synthetic end-to-end probe")
        b.ts("Bandwidth out", [(f'sum(rate(nginx_ingress_controller_response_size_sum{{exported_namespace="{s.ns}", ingress=~"{ing}"}}[$__rate_interval])) or vector(0)', "bytes/s")], unit="Bps", w=8)
    elif s.probe:
        b.row("External probe")
        b.ts("External probe duration", [(f'max(probe_duration_seconds{{probe="external", target_namespace="{s.ns}", target_service="{s.probe}"}})', "probe")], unit="s")
        b.ts("External probe success", [(f'min(probe_success{{probe="external", target_namespace="{s.ns}", target_service="{s.probe}"}})', "up")], min0=True)

    # ---- service specific -------------------------------------------------
    if s.extras:
        b.row("Service metrics")
        for fn in s.extras:
            fn(b, s)

    # ---- resources --------------------------------------------------------
    b.row("Resources")
    cpu_zero = " or vector(0)" if s.kind == "cronjob" else ""
    b.ts("CPU (cores)", [
        (f'sum by (container) (rate(container_cpu_usage_seconds_total{{{kp}, container!="", container!="POD"}}[$__rate_interval])){cpu_zero}', "{{container}}"),
        (f'sum(kube_pod_container_resource_requests{{{kp}, resource="cpu"}})', "request"),
        (f'sum(kube_pod_container_resource_limits{{{kp}, resource="cpu"}})', "limit"),
    ], unit="short", w=8, overrides=limit_overrides())
    b.ts("Memory (working set)", [
        (f'sum by (container) (container_memory_working_set_bytes{{{kp}, container!="", container!="POD"}}){cpu_zero}', "{{container}}"),
        (f'sum(kube_pod_container_resource_requests{{{kp}, resource="memory"}})', "request"),
        (f'sum(kube_pod_container_resource_limits{{{kp}, resource="memory"}})', "limit"),
    ], unit="bytes", w=8, overrides=limit_overrides())
    b.ts("CPU throttling", [
        (f'sum by (container) (rate(container_cpu_cfs_throttled_periods_total{{{kp}, container!=""}}[$__rate_interval])) / sum by (container) (rate(container_cpu_cfs_periods_total{{{kp}, container!=""}}[$__rate_interval])) or vector(0)', "{{container}}"),
    ], unit="percentunit", w=8, desc="share of CPU periods throttled by the CPU limit (0 if no limit)")

    # ---- logs -------------------------------------------------------------
    b.row("Logs")
    b.logs("Logs", f'{sel} | detected_level=~"$level" |~ "(?i)$search"', h=16, time_from="400d" if s.quiet else "30d",
           desc=("this service logs very rarely: looking back 400d (history is archived for that long). " if s.quiet else "") + "newest first. Filter with the level/search variables; expand a line for all parsed fields")
    return b


def limit_overrides():
    return [
        {"matcher": {"id": "byName", "options": "limit"},
         "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "red"}},
                        {"id": "custom.lineStyle", "value": {"fill": "dash", "dash": [10, 10]}},
                        {"id": "custom.fillOpacity", "value": 0}]},
        {"matcher": {"id": "byName", "options": "request"},
         "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "yellow"}},
                        {"id": "custom.lineStyle", "value": {"fill": "dash", "dash": [4, 4]}},
                        {"id": "custom.fillOpacity", "value": 0}]},
    ]


# ----------------------------------------------------------------------------
# Service specific panels
# ----------------------------------------------------------------------------

def arr(app):
    def fn(b: Board, s: Svc):
        b.stat("Health issues", f'sum({app}_system_health_issues) or vector(0)', thresholds=RED_IF_ABOVE_0,
               desc=f"{app} System > Status health checks currently failing")
        b.stat("API reachable", f'max({app}_system_status)', mappings=UPDOWN,
               thresholds=[{"color": "red", "value": None}, {"color": "green", "value": 1}])
        if app in ("sonarr", "radarr", "readarr"):
            b.stat("Root folder free", f'min({app}_rootfolder_freespace_bytes)', unit="bytes",
                   thresholds=[{"color": "red", "value": None}, {"color": "orange", "value": 50e9}, {"color": "green", "value": 200e9}])
        if app == "sonarr":
            b.ts("Queue / missing", [("sum(sonarr_queue_total)", "queue"), ("sum(sonarr_episode_missing_total)", "missing episodes")], w=12)
        if app == "radarr":
            b.ts("Wanted / missing", [("sum(radarr_movie_wanted_total)", "wanted"), ("sum(radarr_movie_missing_total)", "missing")], w=12)
        if app == "readarr":
            b.ts("Books missing / grabbed", [("sum(readarr_book_missing_total)", "missing"), ("sum(readarr_book_grabbed_total)", "grabbed")], w=12)
        if app == "prowlarr":
            b.ts("Indexer query failures", [("sum by (indexer) (increase(prowlarr_indexer_failed_queries_total[1h])) or vector(0)", "{{indexer}}")], w=12, bars=True)
            b.ts("Indexer response time", [("max by (indexer) (prowlarr_indexer_average_response_time_ms)", "{{indexer}}")], unit="ms", w=12)
            b.stat("Unavailable indexers", "sum(prowlarr_indexer_unavailable) or vector(0)", thresholds=RED_IF_ABOVE_0)
    return fn


def adguard_panels(b: Board, s: Svc):
    b.ts("Probes: LAN DNS (10.0.0.71:53) and web UI", [('min by (instance) (probe_success{probe="internal", target_namespace="adguard-home"})', "{{instance}}")],
         desc="1 = up, 0 = down. dns_a = resolves github.com through the LoadBalancer IP the LAN uses; 0 = LAN DNS is broken")
    b.ts("Upstream failures by upstream", [(f'sum by (upstream) (count_over_time({loki_sel(s)} |= "exchange failed" | regexp "upstream=(?P<upstream>[^ ]+)" [$__auto])) or vector(0)', "{{upstream}}")],
         ds=LOKI, bars=True, desc="queries AdGuard could not forward; with parallel upstreams a single failing upstream is harmless, all failing = DNS outage")


def authelia_panels(b: Board, s: Svc):
    b.ts("Authentication attempts", [('sum by (success, type) (increase(authelia_authn[$__rate_interval]))', "success={{success}} {{type}}")], bars=True)
    b.ts("Authorization decisions", [('sum by (type) (increase(authelia_authz[$__rate_interval]))', "{{type}}")], bars=True)
    b.ts("Authelia requests by code", [('sum by (code) (rate(authelia_request[$__rate_interval]))', "{{code}}")], unit="reqps")
    b.ts("Request latency p95", [('histogram_quantile(0.95, sum by (le) (rate(authelia_request_duration_bucket[$__rate_interval])))', "p95")], unit="s")
    b.logs("Failed logins / bans", f'{loki_sel(s)} |~ "(?i)(unsuccessful|failed|banned|regulation)"', h=8, time_from="7d")


def argocd_panels(b: Board, s: Svc):
    b.table("Applications not Synced/Healthy", [
        ('max by (name, sync_status, health_status) (argocd_app_info{sync_status!="Synced"} or argocd_app_info{health_status!="Healthy"}) or on() vector(0)', ""),
    ], w=12, transformations=[{"id": "organize", "options": {"excludeByName": {"Time": True, "Value": True}}}])
    b.ts("Sync operations by phase", [('sum by (phase) (increase(argocd_app_sync_total[1h]))', "{{phase}}")], bars=True, w=12)
    b.stat("Apps OutOfSync", 'count(argocd_app_info{sync_status!="Synced"}) or vector(0)', thresholds=ORANGE_RED)
    b.stat("Apps not Healthy", 'count(argocd_app_info{health_status!="Healthy"}) or vector(0)', thresholds=RED_IF_ABOVE_0)
    b.stat("Cluster connection", 'max(argocd_cluster_connection_status)', mappings=UPDOWN,
           thresholds=[{"color": "red", "value": None}, {"color": "green", "value": 1}])
    b.ts("Reconcile p95", [('histogram_quantile(0.95, sum by (le) (rate(argocd_app_reconcile_bucket[$__rate_interval])))', "p95")], unit="s", w=12)


def cert_manager_panels(b: Board, s: Svc):
    b.table("Certificates (days until expiry)", [
        ('sort((max by (exported_namespace, name) (certmanager_certificate_expiration_timestamp_seconds) - time()) / 86400)', ""),
    ], w=12, transformations=[{"id": "organize", "options": {"excludeByName": {"Time": True}, "renameByName": {"Value": "days left"}}}])
    b.stat("Certificates not Ready", 'count(certmanager_certificate_ready_status{condition="False"} == 1) or vector(0)', thresholds=RED_IF_ABOVE_0)
    b.stat("Soonest expiry", 'min(certmanager_certificate_expiration_timestamp_seconds - time())', unit="s",
           thresholds=[{"color": "red", "value": None}, {"color": "orange", "value": 10 * 86400}, {"color": "green", "value": 21 * 86400}])
    b.ts("ACME requests by status", [('sum by (status) (rate(certmanager_http_acme_client_request_count[$__rate_interval])) or vector(0)', "{{status}}")], unit="reqps")


def eso_panels(b: Board, s: Svc):
    b.stat("ExternalSecrets not Ready", 'count(externalsecret_status_condition{condition="Ready", status="False"} == 1) or vector(0)', thresholds=RED_IF_ABOVE_0)
    b.table("ExternalSecrets failing", [('max by (exported_namespace, name) (externalsecret_status_condition{condition="Ready", status="False"} == 1) or on() vector(0)', "")], w=12,
            transformations=[{"id": "organize", "options": {"excludeByName": {"Time": True, "Value": True}}}])
    b.ts("Sync calls by status", [('sum by (status) (increase(externalsecret_sync_calls_total[1h])) or vector(0)', "{{status}}")], bars=True)
    b.ts("Reconcile errors", [('sum by (controller) (increase(controller_runtime_reconcile_errors_total{namespace="default"}[1h])) or vector(0)', "{{controller}}")], bars=True)


def metallb_panels(b: Board, s: Svc):
    b.ts("Addresses in use", [("sum by (pool) (metallb_allocator_addresses_in_use_total)", "{{pool}} used"), ("sum by (pool) (metallb_allocator_addresses_total)", "{{pool}} total")])
    b.ts("Config stale / k8s update errors", [("max(metallb_k8s_client_config_stale_bool)", "config stale"), ("sum(increase(metallb_k8s_client_update_errors_total[1h])) or vector(0)", "update errors")])


def jellyfin_panels(b: Board, s: Svc):
    b.logs("Playback activity", f'{loki_sel(s)} |~ "(?i)(playback|transcod|stream)"', h=8, time_from="7d", max_lines=200)
    b.ts("Ingress bandwidth out", [('sum(rate(nginx_ingress_controller_response_size_sum{exported_namespace="mediacenter", ingress="jellyfin"}[$__rate_interval])) or vector(0)', "bytes/s")], unit="Bps")


def postgres_panels(b: Board, s: Svc):
    pg = f'namespace="{s.ns}"'
    b.stat("Postgres up (exporter)", f'max(pg_up{{{pg}}})', mappings=UPDOWN, thresholds=[{"color": "red", "value": None}, {"color": "green", "value": 1}])
    b.ts("Connections by database", [(f'sum by (datname) (pg_stat_database_numbackends{{{pg}}})', "{{datname}}")])
    b.ts("Transactions / s", [(f'sum(rate(pg_stat_database_xact_commit{{{pg}}}[$__rate_interval]))', "commit"), (f'sum(rate(pg_stat_database_xact_rollback{{{pg}}}[$__rate_interval]))', "rollback")])
    b.ts("Deadlocks / conflicts", [(f'sum(increase(pg_stat_database_deadlocks{{{pg}}}[$__rate_interval]))', "deadlocks"), (f'sum(increase(pg_stat_database_conflicts{{{pg}}}[$__rate_interval]))', "conflicts")], bars=True)
    b.ts("Database size", [(f'sum by (datname) (pg_database_size_bytes{{{pg}}})', "{{datname}}")], unit="bytes")
    b.ts("Errors by severity", [(f'sum by (detected_level) (count_over_time({loki_sel(s)} | detected_level=~"error|fatal" [$__auto]))', "{{detected_level}}")], ds=LOKI, bars=True, overrides=level_overrides())
    b.logs("FATAL / ERROR", f'{loki_sel(s)} | detected_level=~"error|fatal"', h=8, time_from="7d", max_lines=200)


def ingress_global(b: Board, s: Svc):
    b.ts("Requests / s by ingress", [('sum by (exported_namespace, ingress) (rate(nginx_ingress_controller_requests[$__rate_interval]))', "{{exported_namespace}}/{{ingress}}")], unit="reqps")
    b.ts("5xx / s by ingress", [('sum by (exported_namespace, ingress) (rate(nginx_ingress_controller_requests{status=~"5.."}[$__rate_interval])) or vector(0)', "{{exported_namespace}}/{{ingress}}")], unit="reqps")
    b.ts("p95 latency by ingress", [('histogram_quantile(0.95, sum by (le, ingress) (rate(nginx_ingress_controller_request_duration_seconds_bucket[$__rate_interval])))', "{{ingress}}")], unit="s")
    b.ts("Responses by status class", [('sum by (status_class) (label_replace(rate(nginx_ingress_controller_requests[$__rate_interval]), "status_class", "${1}xx", "status", "(.).."))', "{{status_class}}")], unit="reqps", stack=True, overrides=status_overrides())
    sel = loki_sel(s)
    b.table("Top 5xx paths (access logs, 24h)", [(f'topk(15, sum by (host, path, status) (count_over_time({sel} | status >= 500 [24h]))) or vector(0)', "")], ds=LOKI, w=12,
            transformations=[{"id": "organize", "options": {"excludeByName": {"Time": True}, "renameByName": {"Value": "count"}}}])
    b.table("Top 4xx paths (access logs, 24h)", [(f'topk(15, sum by (host, path, status) (count_over_time({sel} | status >= 400 | status < 500 [24h]))) or vector(0)', "")], ds=LOKI, w=12,
            transformations=[{"id": "organize", "options": {"excludeByName": {"Time": True}, "renameByName": {"Value": "count"}}}])
    b.table("Top clients (24h)", [(f'topk(15, sum by (remote_addr) (count_over_time({sel} | remote_addr != "" [24h])))', "")], ds=LOKI, w=12,
            transformations=[{"id": "organize", "options": {"excludeByName": {"Time": True}, "renameByName": {"Value": "requests"}}}])
    b.ts("Upstream errors (no upstream / 502-504)", [(f'sum by (upstream) (count_over_time({sel} | status=~"502|503|504" [$__auto])) or vector(0)', "{{upstream}}")], ds=LOKI, bars=True, w=12)


def coredns_panels(b: Board, s: Svc):
    b.ts("DNS requests by rcode", [('sum by (rcode) (rate(coredns_dns_responses_total[$__rate_interval]))', "{{rcode}}")], unit="reqps")
    b.ts("DNS latency p95", [('histogram_quantile(0.95, sum by (le) (rate(coredns_dns_request_duration_seconds_bucket[$__rate_interval])))', "p95")], unit="s")
    b.ts("Forward errors / SERVFAIL", [('sum(rate(coredns_dns_responses_total{rcode="SERVFAIL"}[$__rate_interval])) or vector(0)', "SERVFAIL"), ('sum(rate(coredns_proxy_healthcheck_failures_total[$__rate_interval])) or vector(0)', "forward healthcheck failures")], unit="reqps")


def apiserver_panels(b: Board, s: Svc):
    b.ts("API requests by code class", [('sum by (code_class) (label_replace(rate(apiserver_request_total[$__rate_interval]), "code_class", "${1}xx", "code", "(.).."))', "{{code_class}}")], unit="reqps", overrides=status_overrides())
    b.ts("API request latency p99 (non-watch)", [('histogram_quantile(0.99, sum by (le, verb) (rate(apiserver_request_duration_seconds_bucket{verb!~"WATCH|CONNECT"}[$__rate_interval])))', "{{verb}}")], unit="s")


def blackbox_panels(b: Board, s: Svc):
    b.table("Probe status", [
        ('min by (probe, target_namespace, target_service, instance) (probe_success)', ""),
    ], w=12, transformations=[{"id": "organize", "options": {"excludeByName": {"Time": True}, "renameByName": {"Value": "up"}}}],
        overrides=[{"matcher": {"id": "byName", "options": "up"}, "properties": [{"id": "mappings", "value": UPDOWN}, {"id": "custom.cellOptions", "value": {"type": "color-background"}}]}])
    b.table("TLS days left", [('sort(min by (instance) (probe_ssl_earliest_cert_expiry{probe="external"} - time()) / 86400)', "")], w=12,
            transformations=[{"id": "organize", "options": {"excludeByName": {"Time": True}, "renameByName": {"Value": "days"}}}])


def observability_panels(b: Board, s: Svc):
    b.ts("Loki ingest (lines/s by namespace)", [('sum by (k8s_namespace_name) (rate({k8s_namespace_name=~".+"} [$__auto]))', "{{k8s_namespace_name}}")], ds=LOKI, stack=True)
    b.ts("Loki bytes ingested / s", [('sum(rate(loki_distributor_bytes_received_total[$__rate_interval]))', "bytes/s")], unit="Bps")
    b.ts("Alloy export failures", [
        ('sum(rate(otelcol_exporter_send_failed_log_records_total[$__rate_interval])) or vector(0)', "log records"),
        ('sum(rate(otelcol_exporter_send_failed_spans_total[$__rate_interval])) or vector(0)', "spans"),
        ('sum(rate(otelcol_exporter_send_failed_metric_points_total[$__rate_interval])) or vector(0)', "metric points"),
    ])
    b.ts("Alloy export queue", [('sum by (instance) (otelcol_exporter_queue_size)', "{{instance}}")])
    b.ts("Prometheus TSDB size", [('sum(prometheus_tsdb_storage_blocks_bytes) + sum(prometheus_tsdb_wal_storage_size_bytes)', "bytes")], unit="bytes")
    b.ts("Prometheus active series", [('sum(prometheus_tsdb_head_series)', "series")])
    b.ts("Scrape targets down", [('count by (job) (up == 0) or vector(0)', "{{job}}")], bars=True)
    b.ts("Tempo spans received / s", [('sum(rate(tempo_distributor_spans_received_total[$__rate_interval])) or vector(0)', "spans/s")])


def node_panels(b: Board, s: Svc):
    b.ts("Node CPU used", [('1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[$__rate_interval]))', "{{instance}}")], unit="percentunit")
    b.ts("Node memory used", [('1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes', "{{instance}}")], unit="percentunit")
    b.ts("Filesystem used", [('1 - node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs"}', "{{instance}} {{mountpoint}}")], unit="percentunit")
    b.ts("Disk I/O utilisation", [('rate(node_disk_io_time_seconds_total[$__rate_interval])', "{{instance}} {{device}}")], unit="percentunit")
    b.ts("Network receive", [('sum by (instance) (rate(node_network_receive_bytes_total{device!~"lo|veth.*|cni.*|flannel.*"}[$__rate_interval]))', "{{instance}}")], unit="Bps")
    b.ts("Network transmit", [('sum by (instance) (rate(node_network_transmit_bytes_total{device!~"lo|veth.*|cni.*|flannel.*"}[$__rate_interval]))', "{{instance}}")], unit="Bps")
    b.ts("Load (1m) per core", [('node_load1 / on (instance) group_left () count by (instance) (node_cpu_seconds_total{mode="idle"})', "{{instance}}")])
    b.ts("Pods per node", [('count by (node) (kube_pod_info)', "{{node}}")])


# ----------------------------------------------------------------------------
# Catalog of every service in the repo
# ----------------------------------------------------------------------------

def S(*a, **k):
    return Svc(*a, **k)


CATALOG: List[Svc] = [
    # --- apps ----------------------------------------------------------------
    S("anki", "anki", "Anki sync server", ingress=["anki"], probe="anki", folder="Apps"),
    S("homeassistant", "homeassistant", "Home Assistant", ingress=["homeassistant"], probe="homeassistant", folder="Home Assistant"),
    S("homeassistant", "hamh", "Home Assistant Matter Hub (hamh)", ingress=["hamh"], probe="hamh", folder="Home Assistant"),
    S("homeassistant", "matter-server", "Matter server", folder="Home Assistant"),
    S("homepage", "homepage", "Homepage (tkuipers.ca)", ingress=["homepage", "resume-proxy"], probe="homepage", access_logs=True, folder="Apps"),

    S("mediacenter", "jellyfin", "Jellyfin", ingress=["jellyfin"], probe="jellyfin", folder="Media", extras=[jellyfin_panels]),
    S("mediacenter", "jellyseerr", "Jellyseerr", ingress=["jellyseerr"], probe="jellyseerr", folder="Media"),
    S("mediacenter", "sonarr", "Sonarr", ingress=["sonarr"], probe="sonarr", folder="Media", extras=[arr("sonarr")]),
    S("mediacenter", "radarr", "Radarr", ingress=["radarr"], probe="radarr", folder="Media", extras=[arr("radarr")]),
    S("mediacenter", "readarr", "Readarr", ingress=["readarr"], probe="readarr", folder="Media", extras=[arr("readarr")]),
    S("mediacenter", "prowlarr", "Prowlarr", ingress=["prowlarr"], probe="prowlarr", folder="Media", extras=[arr("prowlarr")]),
    S("mediacenter", "bazarr", "Bazarr", ingress=["bazarr"], probe="bazarr", folder="Media"),
    S("mediacenter", "kavita", "Kavita", ingress=["kavita"], probe="kavita", folder="Media"),
    S("mediacenter", "sabnzbd", "SABnzbd (+gluetun VPN)", ingress=["sabnzbd"], probe="sabnzbd", folder="Media"),
    S("mediacenter", "transmission", "Transmission (+gluetun VPN)", ingress=["transmission"], probe="transmission", folder="Media"),
    S("mediacenter", "transmission-cleanup", "Transmission cleanup (CronJob)", kind="cronjob", folder="Media"),

    S("polymarket-bot", "bot", "Polymarket bot", ingress=["bot"], probe="bot", folder="Polymarket"),
    S("polymarket-bot", "postgres", "Polymarket Postgres", folder="Polymarket", extras=[postgres_panels]),
    S("polymarket-bot", "postgres-backup", "Polymarket Postgres backup (CronJob)", kind="cronjob", folder="Polymarket"),

    S("stock-guesser", "stock-guesser-app", "Stock Guesser app", access_logs=True, folder="Stock Guesser"),
    S("stock-guesser", "mysql", "Stock Guesser MySQL", folder="Stock Guesser"),
    S("stock-guesser", "stock-guesser-data-builder", "Stock Guesser data builder (CronJob)", kind="cronjob", folder="Stock Guesser"),
    S("stock-guesser", "stock-guesser-training", "Stock Guesser training (CronJob)", kind="cronjob", folder="Stock Guesser"),
    S("stock-guesser", "mysql-backup", "Stock Guesser MySQL backup (CronJob)", kind="cronjob", folder="Stock Guesser"),

    S("stocks", "api", "Stocks API", ingress=["api"], probe="api", access_logs=True, folder="Stocks"),
    S("stocks", "console", "Stocks console", ingress=["console"], probe="console", access_logs=True, folder="Stocks"),
    S("stocks", "audit-consumer", "Stocks audit consumer", folder="Stocks"),
    S("stocks", "decision", "Stocks decision", access_logs=True, folder="Stocks"),
    S("stocks", "ingestion", "Stocks ingestion", access_logs=True, folder="Stocks"),
    S("stocks", "llm-gateway", "Stocks LLM gateway", access_logs=True, folder="Stocks"),
    S("stocks", "orchestrator", "Stocks orchestrator", access_logs=True, folder="Stocks"),
    S("stocks", "paper-filler", "Stocks paper filler", access_logs=True, folder="Stocks"),
    S("stocks", "training", "Stocks training", access_logs=True, folder="Stocks"),
    S("stocks", "minio", "Stocks MinIO", folder="Stocks"),
    S("stocks", "nats", "Stocks NATS", folder="Stocks"),
    S("stocks", "postgres", "Stocks Postgres", folder="Stocks", extras=[postgres_panels]),
    S("stocks", "redis", "Stocks Redis", folder="Stocks", quiet=True),
    S("stocks", "postgres-backup", "Stocks Postgres backup (CronJob)", kind="cronjob", folder="Stocks"),

    # --- infrastructure ----------------------------------------------------
    S("adguard-home", "adguard-home", "AdGuard Home (DNS)", ingress=["adguard-home"], probe="adguard-home", folder="Infrastructure", extras=[adguard_panels]),
    S("authelia", "authelia", "Authelia (SSO)", ingress=["authelia"], probe="authelia", folder="Infrastructure", extras=[authelia_panels]),
    S("authelia", "authelia-redis", "Authelia Redis", folder="Infrastructure"),
    S("aws-ip-updater", "aws-ip-updater", "AWS dynamic DNS updater (CronJob)", kind="cronjob", folder="Infrastructure"),
    S("cert-manager", "infrastructure-cert-manager", "cert-manager", folder="Infrastructure", extras=[cert_manager_panels]),
    S("cert-manager", "infrastructure-cert-manager-cainjector", "cert-manager cainjector", folder="Infrastructure"),
    S("cert-manager", "infrastructure-cert-manager-webhook", "cert-manager webhook", folder="Infrastructure"),
    S("nfs-provisioner", "csi-smb-controller", "CSI SMB controller", folder="Infrastructure", quiet=True),
    S("nfs-provisioner", "csi-smb-node", "CSI SMB node", kind="daemonset", folder="Infrastructure"),
    S("nfs-provisioner", "samba-server-dell-r620", "Samba server (dell-r620)", folder="Infrastructure", quiet=True),
    S("nfs-provisioner", "samba-server-omen-worker1", "Samba server (omen-worker1)", folder="Infrastructure", quiet=True),
    S("external-dns", "external-dns", "external-dns", folder="Infrastructure"),
    S("ingress-nginx", "infrastructure-ingress-nginx-controller", "Ingress NGINX", access_logs=True, probe="kubernetes-api-proxy", folder="Infrastructure",
      extras=[ingress_global], description="All HTTP traffic into the cluster. Per-service views live in each service dashboard."),
    S("local-path-storage", "local-path-provisioner", "local-path provisioner", folder="Infrastructure", quiet=True),
    S("metallb-system", "infrastructure-metallb-controller", "MetalLB controller", folder="Infrastructure", extras=[metallb_panels]),
    S("metallb-system", "infrastructure-metallb-speaker", "MetalLB speaker", kind="daemonset", folder="Infrastructure"),
    S("nvidia-device-plugin", "nvidia-device-plugin", "NVIDIA device plugin", kind="daemonset", folder="Infrastructure", quiet=True),
    S("default", "external-secrets", "External Secrets Operator", folder="Infrastructure", extras=[eso_panels], quiet=True),
    S("default", "external-secrets-cert-controller", "External Secrets cert controller", folder="Infrastructure"),
    S("default", "external-secrets-webhook", "External Secrets webhook", folder="Infrastructure"),
    S("default", "op-connect", "1Password Connect", folder="Infrastructure"),

    S("argocd", "argocd-server", "Argo CD server", ingress=["argocd-server-ingress"], probe="argocd-server", folder="Argo CD", extras=[argocd_panels]),
    S("argocd", "argocd-application-controller", "Argo CD application controller", kind="statefulset", folder="Argo CD"),
    S("argocd", "argocd-repo-server", "Argo CD repo server", folder="Argo CD"),
    S("argocd", "argocd-applicationset-controller", "Argo CD applicationset controller", folder="Argo CD"),
    S("argocd", "argocd-notifications-controller", "Argo CD notifications controller", folder="Argo CD"),
    S("argocd", "argocd-dex-server", "Argo CD dex", folder="Argo CD"),
    S("argocd", "argocd-redis", "Argo CD redis", folder="Argo CD", quiet=True),

    S("kube-system", "coredns", "CoreDNS", folder="Kubernetes", extras=[coredns_panels]),
    S("kube-system", "kube-apiserver", "kube-apiserver", kind="static", folder="Kubernetes", extras=[apiserver_panels]),
    S("kube-system", "kube-controller-manager", "kube-controller-manager", kind="static", folder="Kubernetes"),
    S("kube-system", "kube-scheduler", "kube-scheduler", kind="static", folder="Kubernetes"),
    S("kube-system", "kube-proxy", "kube-proxy", kind="daemonset", folder="Kubernetes"),
    S("kube-system", "kube-flannel", "Flannel (CNI)", kind="daemonset", folder="Kubernetes"),

    S("observability", "kps-grafana", "Grafana", ingress=["kps-grafana"], probe="grafana", folder="Observability"),
    S("observability", "prometheus-kps", "Prometheus", kind="statefulset", folder="Observability", extras=[observability_panels]),
    S("observability", "loki", "Loki", kind="statefulset", folder="Observability"),
    S("observability", "tempo", "Tempo", kind="statefulset", folder="Observability"),
    S("observability", "alloy", "Alloy (node collector)", kind="daemonset", folder="Observability"),
    S("observability", "alloy-events", "Alloy (k8s events)", folder="Observability"),
    S("observability", "alertmanager-kps", "Alertmanager", kind="statefulset", folder="Observability"),
    S("observability", "kps-kube-state-metrics", "kube-state-metrics", folder="Observability"),
    S("observability", "kps-prometheus-node-exporter", "node-exporter", kind="daemonset", folder="Observability", extras=[node_panels]),
    S("observability", "kps-operator", "Prometheus operator", folder="Observability"),
    S("observability", "blackbox", "Blackbox exporter (probes)", folder="Observability", extras=[blackbox_panels]),
]


# ----------------------------------------------------------------------------
# Overview dashboards
# ----------------------------------------------------------------------------

def overview() -> Board:
    b = Board("homelab-overview", "Homelab overview", ["homelab", "overview"], "Overview",
              description="Start here during an incident: what is down, failing or restarting right now.")
    b.text("", "**Start here.** Red = act now. Every service has its own dashboard (*Services* dropdown above). "
               "Logs: *Explore* → Loki, or the Logs app. Alerts: *Alerting* → Alert rules.", h=2)
    b.row("Right now")
    b.stat("Health checks failing", 'count(probe_success{probe="internal"} == 0) or vector(0)', thresholds=RED_IF_ABOVE_0, w=4,
           desc="in-cluster health probes (the apps themselves) currently failing")
    b.stat("Public URLs failing", 'count(probe_success{probe="external"} == 0) or vector(0)', thresholds=RED_IF_ABOVE_0, w=4,
           desc="public *.tkuipers.ca probes (DNS/ingress/TLS/Authelia) failing")
    b.stat("Workloads not ready",
           '(count(kube_deployment_status_replicas_available - kube_deployment_spec_replicas < 0) or vector(0)) + (count(kube_statefulset_status_replicas_ready - kube_statefulset_replicas < 0) or vector(0)) + (count(kube_daemonset_status_number_ready - kube_daemonset_status_desired_number_scheduled < 0) or vector(0))',
           thresholds=RED_IF_ABOVE_0, w=4)
    b.stat("Pods crash-looping", 'count(kube_pod_container_status_waiting_reason{reason=~"CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerConfigError"}) or vector(0)', thresholds=RED_IF_ABOVE_0, w=4)
    b.stat("Restarts (1h)", 'sum(increase(kube_pod_container_status_restarts_total[1h])) or vector(0)', thresholds=ORANGE_RED, w=4, decimals=0)
    b.stat("Ingress 5xx (1h)", '(sum(rate(nginx_ingress_controller_requests{status=~"5.."}[1h])) or vector(0)) / sum(rate(nginx_ingress_controller_requests[1h]))', unit="percentunit", decimals=2,
           thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 0.01}, {"color": "red", "value": 0.05}], w=4)
    b.stat("Firing alerts", '(count(ALERTS{alertstate="firing", alertname!~"Watchdog|InfoInhibitor"}) or vector(0)) + (sum(grafana_alerting_alerts{state="alerting"}) or vector(0))',
           thresholds=ORANGE_RED, w=4, desc="Grafana-managed (folder Alerts) + Prometheus (kube-prometheus-stack) alerts")
    b.alertlist("Firing / pending alerts", w=12, h=9)
    b.table("Problems", [
        ('max by (namespace, pod, container, reason) (kube_pod_container_status_waiting_reason{reason!="ContainerCreating"}) or on() vector(0)', ""),
    ], w=12, h=9, desc="containers waiting (CrashLoopBackOff, ImagePullBackOff, ...)",
        transformations=[{"id": "organize", "options": {"excludeByName": {"Time": True, "Value": True}}}])
    b.row("Failure rates")
    b.ts("Error-level log lines by service", [('topk(15, sum by (k8s_namespace_name, service_name) (count_over_time({k8s_namespace_name=~".+"} | detected_level=~"error|fatal|critical" [$__auto]))) or vector(0)', "{{k8s_namespace_name}}/{{service_name}}")],
         ds=LOKI, bars=True, stack=True, w=12)
    b.ts("Ingress 5xx / s by ingress", [('sum by (exported_namespace, ingress) (rate(nginx_ingress_controller_requests{status=~"5.."}[$__rate_interval])) or vector(0)', "{{exported_namespace}}/{{ingress}}")], unit="reqps", w=12)
    b.ts("Container restarts by pod", [('sum by (namespace, pod) (increase(kube_pod_container_status_restarts_total[10m])) > 0 or vector(0)', "{{namespace}}/{{pod}}")], bars=True, w=12)
    b.ts("Probe failures", [('count by (probe, target_namespace, target_service) (probe_success == 0) or vector(0)', "{{probe}} {{target_namespace}}/{{target_service}}")], bars=True, w=12)
    b.table("CronJobs: time since last success", [('sort_desc(time() - max by (namespace, cronjob) (kube_cronjob_status_last_successful_time))', "")], w=12,
            transformations=[{"id": "organize", "options": {"excludeByName": {"Time": True}, "renameByName": {"Value": "seconds since success"}}}],
            overrides=[{"matcher": {"id": "byName", "options": "seconds since success"}, "properties": [{"id": "unit", "value": "s"}]}])
    b.table("Failed Jobs (started in the last 7d)", [('max by (namespace, job_name) (kube_job_status_failed > 0) and on (namespace, job_name) (time() - kube_job_status_start_time < 7 * 86400) or on() vector(0)', "")], w=12,
            transformations=[{"id": "organize", "options": {"excludeByName": {"Time": True}, "renameByName": {"Value": "failed pods"}}}])
    b.row("Cluster")
    node_panels(b, None)
    b.row("Service dashboards")
    b.dashlist("All service dashboards", "service", h=14)
    return b


def stocks_pipeline(b: Board):
    """Is the trading pipeline actually moving? (pods can be Ready while it is stuck)"""
    b.row("Pipeline activity")
    b.stat("Ingestion runs (3h)", 'sum(count_over_time({k8s_namespace_name="stocks", service_name="ingestion"} |= "pipeline_complete" [3h]))',
           ds=LOKI, no_value="NONE", thresholds=[{"color": "red", "value": None}, {"color": "green", "value": 1}],
           desc="'pipeline_complete' events from ingestion (runs hourly)")
    b.stat("Decisions (26h)", 'sum(count_over_time({k8s_namespace_name="stocks", service_name="decision"} |= "decision.predicted" [26h]))',
           ds=LOKI, no_value="NONE", thresholds=[{"color": "red", "value": None}, {"color": "green", "value": 1}],
           desc="'decision.predicted' events from the decision service")
    b.stat("Consumer backlog (max)", 'max(jetstream_consumer_num_pending)', thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 50}, {"color": "red", "value": 500}],
           desc="largest number of messages waiting for a JetStream consumer")
    b.stat("Redeliveries (1h)", 'sum(increase(jetstream_consumer_num_redelivered[1h]))', thresholds=ORANGE_RED, decimals=0,
           desc="messages delivered more than once - consumers failing to ack")
    b.stat("ERROR events (1h)", 'sum(count_over_time({k8s_namespace_name="stocks"} | detected_level=~"error|fatal|critical" [1h])) or (sum(count_over_time({k8s_namespace_name="stocks"} [1h])) * 0)',
           ds=LOKI, thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 1}, {"color": "red", "value": 20}])
    b.stat("Postgres up", 'max(pg_up{namespace="stocks"})', mappings=UPDOWN, thresholds=[{"color": "red", "value": None}, {"color": "green", "value": 1}])
    b.ts("JetStream consumer backlog", [('max by (stream_name, consumer_name) (jetstream_consumer_num_pending)', "{{stream_name}} -> {{consumer_name}}")], w=12)
    b.ts("Messages published per stream", [('sum by (stream_name) (increase(jetstream_stream_last_seq[$__rate_interval]))', "{{stream_name}}")], bars=True, stack=True, w=12)
    b.ts("Ack pending / redelivered", [('sum by (consumer_name) (jetstream_consumer_num_ack_pending)', "ack pending {{consumer_name}}"),
                                        ('sum by (consumer_name) (increase(jetstream_consumer_num_redelivered[$__rate_interval]))', "redelivered {{consumer_name}}")], w=12)
    b.ts("Business events", [('sum by (service_name) (count_over_time({k8s_namespace_name="stocks", service_name=~"ingestion|decision|orchestrator|paper-filler|audit-consumer|training"} | log_format="json" [$__auto]))', "{{service_name}}")],
         ds=LOKI, bars=True, stack=True, w=12, desc="structured (JSON) events per service = real work, not health checks")


def namespace_overview(ns: str, title: str, folder: str) -> Board:
    b = Board(f"ns-{ns}", f"{title} - overview", ["homelab", "namespace", ns], folder,
              description=f"Every workload in namespace {ns}")
    b.add_level_search_vars()
    if ns == "stocks":
        stocks_pipeline(b)
    b.row("Workloads")
    b.table("Workload readiness", [
        (f'max by (deployment) (kube_deployment_status_replicas_available{{namespace="{ns}"}})', "ready"),
        (f'max by (deployment) (kube_deployment_spec_replicas{{namespace="{ns}"}})', "desired"),
    ], w=12, h=10, transformations=[{"id": "merge", "options": {}},
                                    {"id": "organize", "options": {"excludeByName": {"Time": True}, "renameByName": {"Value #A": "ready", "Value #B": "desired"}}}])
    b.ts("Restarts by pod", [(f'sum by (pod) (increase(kube_pod_container_status_restarts_total{{namespace="{ns}"}}[10m])) or vector(0)', "{{pod}}")], bars=True, w=12, h=10)
    b.ts("Error logs by service", [(f'sum by (service_name) (count_over_time({{k8s_namespace_name="{ns}"}} | detected_level=~"error|fatal|critical" [$__auto])) or vector(0)', "{{service_name}}")], ds=LOKI, bars=True, stack=True)
    b.ts("Logs by level", [(f'sum by (detected_level) (count_over_time({{k8s_namespace_name="{ns}"}} [$__auto]))', "{{detected_level}}")], ds=LOKI, bars=True, stack=True, overrides=level_overrides())
    b.ts("CPU by pod", [(f'sum by (pod) (rate(container_cpu_usage_seconds_total{{namespace="{ns}", container!=""}}[$__rate_interval]))', "{{pod}}")])
    b.ts("Memory by pod", [(f'sum by (pod) (container_memory_working_set_bytes{{namespace="{ns}", container!=""}})', "{{pod}}")], unit="bytes")
    b.row("Logs")
    b.logs("Warnings & errors", f'{{k8s_namespace_name="{ns}"}} | detected_level=~"warn|error|fatal|critical" |~ "(?i)$search"', h=12, time_from="30d")
    b.logs("Kubernetes events", f'{{service_name="kubernetes-events", k8s_namespace_name="{ns}"}}', h=10, time_from="30d")
    return b


NAMESPACE_OVERVIEWS = [
    ("mediacenter", "Media", "Media"), ("stocks", "Stocks", "Stocks"), ("stock-guesser", "Stock Guesser", "Stock Guesser"),
    ("homeassistant", "Home Assistant", "Home Assistant"), ("polymarket-bot", "Polymarket", "Polymarket"),
    ("argocd", "Argo CD", "Argo CD"), ("observability", "Observability", "Observability"),
]


# ----------------------------------------------------------------------------

def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")


def main():
    os.makedirs(OUT, exist_ok=True)
    for f in os.listdir(OUT):
        if f.endswith(".json"):
            os.remove(os.path.join(OUT, f))
    boards = [overview()] + [namespace_overview(*x) for x in NAMESPACE_OVERVIEWS] + [standard(s) for s in CATALOG]
    uids = set()
    gens = []
    for b in boards:
        assert b.uid not in uids, b.uid
        uids.add(b.uid)
        fname = f"{slug(b.folder)}--{slug(b.uid)}.json"
        with open(os.path.join(OUT, fname), "w") as fh:
            json.dump(b.render(), fh, indent=1, sort_keys=True)
            fh.write("\n")
        gens.append((fname, b.folder))
    with open(os.path.join(OUT, "kustomization.yaml"), "w") as fh:
        fh.write("# GENERATED by tooling/observability/generate_dashboards.py - do not edit by hand\n")
        fh.write("apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nnamespace: observability\n\n")
        fh.write("generatorOptions:\n  disableNameSuffixHash: true\n  labels:\n    grafana_dashboard: \"1\"\n\n")
        fh.write("configMapGenerator:\n")
        for fname, folder in gens:
            name = "dash-" + fname[:-5].replace("--", "-")
            name = name[:63].rstrip("-")
            fh.write(f"  - name: {name}\n    files:\n      - {fname}\n    options:\n      annotations:\n        grafana_folder: \"{folder}\"\n")
    print(f"wrote {len(boards)} dashboards to {OUT}")


if __name__ == "__main__":
    main()
