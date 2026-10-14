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
  - Tempo (uid tempo): traces. Their RED metrics come from Tempo's metrics
    generator as traces_spanmetrics_* in Prometheus (labels service,
    k8s_namespace_name, span_name, span_kind, status_code).
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
TEMPO = {"type": "tempo", "uid": "tempo"}

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
    traces: Optional[str] = None  # service.name of its spans when it isn't the workload name (see trace_service)


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


# Who sends traces (service.name = workload name unless Svc.traces says otherwise):
# our own services (OpenTelemetry SDKs) ...
SDK_TRACED = {
    ("stocks", n) for n in ("api", "console", "audit-consumer", "decision", "ingestion", "llm-gateway",
                            "orchestrator", "paper-filler", "training")
} | {("polymarket-bot", "bot"), ("homelab-agent", "homelab-agent"),
     ("argocd", "argocd-server"), ("argocd", "argocd-repo-server")}
# ... and every Deployment in the namespaces Beyla instruments
# (helm-chart-beyla/values.yaml discovery.instrument).
BEYLA_NAMESPACES = {"mediacenter", "homeassistant", "anki", "authelia"}
NOT_TRACED = {("homeassistant", "matter-server")}  # websocket only, nothing Beyla traces


def trace_service(s: Svc) -> Optional[str]:
    """service.name of the workload's spans, None if it sends none."""
    if s.traces:
        return s.traces
    if (s.ns, s.name) in NOT_TRACED:
        return None
    if (s.ns, s.name) in SDK_TRACED or (s.ns in BEYLA_NAMESPACES and s.kind == "deployment"):
        return {"bot": "polymarket-bot"}.get(s.name, s.name)
    return None


def span_sel(s: Svc, extra: str = "") -> str:
    sel = f'service="{trace_service(s)}", k8s_namespace_name="{s.ns}"'
    return sel + (", " + extra if extra else "")


# spans that are the service doing work: requests it serves, messages it handles, jobs it runs
WORK_KINDS = 'span_kind=~"SPAN_KIND_SERVER|SPAN_KIND_CONSUMER"'


# ----------------------------------------------------------------------------
# Panel builders
# ----------------------------------------------------------------------------

class Board:
    def __init__(self, uid, title, tags, folder, time_from="now-24h", description=""):
        self.uid, self.title, self.tags, self.folder = uid, title, tags, folder
        self.time_from, self.description = time_from, description
        self.panels, self.x, self.y, self.row_h, self.pid = [], 0, 0, 0, 1
        self.variables = []
        self.editable = True

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

    def timeline(self, title, targets, w=24, h=8, desc="", up_down=True):
        """State timeline: one lane per series; 1 = up (green), 0 = down (red)."""
        mappings = [{"type": "value", "options": {"0": {"text": "DOWN", "color": "red"},
                                                  "1": {"text": "UP", "color": "green"}}}] if up_down else []
        p = {
            "type": "state-timeline", "title": title, "description": desc, "datasource": PROM,
            "targets": [target(PROM, e, legend=l, ref=chr(65 + i)) for i, (e, l) in enumerate(targets)],
            "fieldConfig": {"defaults": {"mappings": mappings, "color": {"mode": "thresholds"},
                                         "thresholds": {"mode": "absolute", "steps": [{"color": "red", "value": None}, {"color": "green", "value": 1}]}},
                            "overrides": []},
            "options": {"showValue": "never", "rowHeight": 0.8, "mergeValues": True, "alignValue": "left",
                        "legend": {"showLegend": False}},
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

    def traces_table(self, title, traceql, w=24, h=8, desc="", limit=20):
        p = {
            "type": "table", "title": title, "description": desc, "datasource": TEMPO,
            "targets": [{"datasource": TEMPO, "refId": "A", "queryType": "traceql", "query": traceql,
                         "limit": limit, "tableType": "traces"}],
            "fieldConfig": {"defaults": {}, "overrides": []},
            "options": {"showHeader": True, "cellHeight": "sm"},
        }
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

    def alertlist(self, title, w=24, h=8, label_filter=""):
        p = {"type": "alertlist", "title": title,
             "options": {"viewMode": "list", "groupMode": "default", "maxItems": 50,
                         "sortOrder": 1, "dashboardAlerts": False, "alertInstanceLabelFilter": label_filter,
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
            "timezone": "browser", "editable": self.editable, "graphTooltip": 1, "schemaVersion": 39,
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

    # ---- traces -----------------------------------------------------------
    if trace_service(s):
        traces_row(b, s)

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


def traces_row(b: Board, s: Svc):
    sp = span_sel(s)
    work = span_sel(s, WORK_KINDS)
    out = span_sel(s, 'span_kind=~"SPAN_KIND_CLIENT|SPAN_KIND_PRODUCER"')
    b.row("Traces (Tempo)")
    b.ts("Work / s by operation", [
        (f'topk(10, sum by (span_name) (rate(traces_spanmetrics_calls_total{{{work}}}[$__rate_interval])))', "{{span_name}}"),
    ], unit="ops", w=8, stack=True,
        desc="requests served and messages handled per second, from the service's spans (top 10 operations)")
    b.ts("Errors (share of requests / messages)", [
        (f'(sum(rate(traces_spanmetrics_calls_total{{{work}, status_code="STATUS_CODE_ERROR"}}[$__rate_interval])) or vector(0)) / sum(rate(traces_spanmetrics_calls_total{{{work}}}[$__rate_interval]))', "error share"),
    ], unit="percentunit", w=8, desc="server/consumer spans with error status (HTTP 5xx, failed handler) over all of them")
    b.ts("Latency (requests / messages)", [
        (f'histogram_quantile(0.5, sum by (le) (rate(traces_spanmetrics_latency_bucket{{{work}}}[$__rate_interval])))', "p50"),
        (f'histogram_quantile(0.95, sum by (le) (rate(traces_spanmetrics_latency_bucket{{{work}}}[$__rate_interval])))', "p95"),
        (f'histogram_quantile(0.99, sum by (le) (rate(traces_spanmetrics_latency_bucket{{{work}}}[$__rate_interval])))', "p99"),
    ], unit="s", w=8)
    internal = span_sel(s, 'span_kind="SPAN_KIND_INTERNAL"')
    b.ts("Internal operations / s (jobs, loops, tool calls)", [
        (f'topk(10, sum by (span_name) (rate(traces_spanmetrics_calls_total{{{internal}}}[$__rate_interval])))', "{{span_name}}"),
        (f'sum(rate(traces_spanmetrics_calls_total{{{internal}, status_code="STATUS_CODE_ERROR"}}[$__rate_interval])) or vector(0)', "failed (all)"),
    ], unit="ops", w=12,
        desc="spans the service creates around its own work: scheduler jobs and polling loops, agent turns and tool calls, framework internals")
    b.table("Slowest operations (p95, last 1h)", [
        (f'topk(15, histogram_quantile(0.95, sum by (le, span_kind, span_name) (rate(traces_spanmetrics_latency_bucket{{{sp}, span_kind!="SPAN_KIND_CLIENT"}}[1h]))) > 0)', ""),
    ], w=12, desc="server, consumer and internal spans (background jobs: agent turns, scans, ...)",
        transformations=[{"id": "organize", "options": {"excludeByName": {"Time": True}, "renameByName": {"Value": "p95 (s)"}}}])
    b.ts("Calls out / s by target (client spans)", [
        (f'topk(10, sum by (span_name) (rate(traces_spanmetrics_calls_total{{{out}}}[$__rate_interval])))', "{{span_name}}"),
    ], unit="ops", w=12, stack=True,
        desc="what the service calls while working: databases, other services, external APIs, published messages")
    name = trace_service(s)
    b.traces_table("Recent traces with errors",
                   f'{{resource.service.name="{name}" && resource.k8s.namespace.name="{s.ns}" && status=error}}',
                   w=12, desc="click a trace ID to open it; spans link to their log lines")
    b.traces_table("Slowest recent traces",
                   f'{{resource.service.name="{name}" && resource.k8s.namespace.name="{s.ns}" && trace:duration > 1s}}',
                   w=12, desc="traces this service is part of that took more than 1s in total (requests, messages, background jobs)")


def browser_panels(b: Board, s: Svc):
    """tkuipers.ca as visitors' browsers see it (Grafana Faro -> alloy-faro -> Loki)."""
    # production only (tests post app_environment=selftest)
    sel = '{k8s_namespace_name="homepage", service_name="homepage-browser"} |= "app_environment=production"'
    b.ts("Page views (browser)", [
        (f'sum(count_over_time({sel} | kind="event" |= "event_name=page_view" [$__auto])) or vector(0)', "page views"),
        (f'sum(count_over_time({sel} | kind="event" |= "event_name=session_start" [$__auto])) or vector(0)', "new sessions"),
    ], ds=LOKI, bars=True, w=8)
    b.ts("JavaScript errors (browser)", [
        (f'sum by (type) (count_over_time({sel} | kind="exception" | logfmt | keep type [$__auto])) or vector(0)', "{{type}}"),
    ], ds=LOKI, bars=True, stack=True, w=8, desc="uncaught exceptions and console errors in visitors' browsers")
    b.ts("Web vitals p75 (LCP, FCP, TTFB, INP)", [
        (f'quantile_over_time(0.75, {sel} | kind="measurement" | logfmt | unwrap {m} [$__auto]) by (k8s_namespace_name)', m)
        for m in ("lcp", "fcp", "ttfb", "inp")
    ], ds=LOKI, unit="ms", w=8, desc="75th percentile of Faro's web-vitals measurements (Google's 'good': LCP < 2500ms, INP < 200ms)")
    b.logs("Browser errors", f'{sel} | kind="exception"', h=10, time_from="7d",
           desc="JavaScript exceptions from visitors' browsers, newest first")


def tracing_panels(b: Board, s: Svc):
    """Trace pipeline (Beyla dashboard): who sends spans and whether they arrive."""
    b.ts("Spans / s by service (span metrics)", [
        ('topk(15, sum by (k8s_namespace_name, service) (rate(traces_spanmetrics_calls_total[$__rate_interval])))', "{{k8s_namespace_name}}/{{service}}"),
    ], unit="ops", w=12, stack=True)
    b.ts("Alloy OTLP spans in / refused", [
        ('sum(rate(otelcol_receiver_accepted_spans_total[$__rate_interval]))', "accepted"),
        ('sum(rate(otelcol_receiver_refused_spans_total[$__rate_interval])) or vector(0)', "refused"),
        ('sum(rate(otelcol_receiver_failed_spans_total[$__rate_interval])) or vector(0)', "failed"),
    ], unit="ops", w=12)
    b.ts("Spans exported to Tempo / failed", [
        ('sum(rate(otelcol_exporter_sent_spans_total[$__rate_interval]))', "sent"),
        ('sum(rate(otelcol_exporter_send_failed_spans_total[$__rate_interval])) or vector(0)', "failed"),
    ], unit="ops", w=12)
    b.ts("Tempo: spans received / discarded", [
        ('sum(rate(tempo_distributor_spans_received_total[$__rate_interval]))', "received"),
        ('sum by (reason) (rate(tempo_discarded_spans_total[$__rate_interval])) or vector(0)', "discarded {{reason}}"),
    ], unit="ops", w=12, desc="discarded = rate limited, trace too large, ... (reason)")


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


def redis_panels(b: Board, s: Svc):
    """redis_exporter (observability/exporters/redis-exporter.yaml), one target per Redis."""
    t = f'target_namespace="{s.ns}", target_service="{s.name}"'
    b.stat("Redis up", f'max(redis_up{{{t}}})', mappings=UPDOWN, thresholds=[{"color": "red", "value": None}, {"color": "green", "value": 1}])
    b.stat("Memory vs maxmemory", f'max(redis_memory_used_bytes{{{t}}}) / (max(redis_memory_max_bytes{{{t}}}) > 0)', unit="percentunit",
           thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 0.8}, {"color": "red", "value": 0.95}],
           no_value="no maxmemory", desc="at maxmemory Redis evicts keys (allkeys-lru) or refuses writes, depending on its policy")
    b.stat("Keys", f'sum(redis_db_keys{{{t}}})', no_value="empty")
    b.ts("Memory", [(f'max(redis_memory_used_bytes{{{t}}})', "used"), (f'max(redis_memory_used_rss_bytes{{{t}}})', "rss"),
                    (f'max(redis_memory_max_bytes{{{t}}}) > 0', "maxmemory")], unit="bytes", w=8)
    b.ts("Commands / s and hit ratio", [
        (f'sum(rate(redis_commands_processed_total{{{t}}}[$__rate_interval]))', "commands/s"),
        (f'sum(rate(redis_keyspace_hits_total{{{t}}}[$__rate_interval])) / (sum(rate(redis_keyspace_hits_total{{{t}}}[$__rate_interval])) + sum(rate(redis_keyspace_misses_total{{{t}}}[$__rate_interval])))', "hit ratio"),
    ], w=8)
    b.ts("Clients / evictions", [
        (f'max(redis_connected_clients{{{t}}})', "clients"),
        (f'sum(increase(redis_evicted_keys_total{{{t}}}[$__rate_interval])) or vector(0)', "evicted keys"),
        (f'sum(increase(redis_rejected_connections_total{{{t}}}[$__rate_interval])) or vector(0)', "rejected connections"),
    ], w=8)


def sabnzbd_panels(b: Board, s: Svc):
    b.stat("API reachable", 'max(sabnzbd_status)', mappings=UPDOWN, thresholds=[{"color": "red", "value": None}, {"color": "green", "value": 1}])
    b.stat("Paused", 'max(sabnzbd_paused)', mappings=[{"type": "value", "options": {"0": {"text": "no", "color": "green"}, "1": {"text": "PAUSED", "color": "orange"}}}])
    b.stat("Queue", 'max(sabnzbd_queue_length)', desc="jobs in the download queue")
    b.stat("Download disk used", 'max(sabnzbd_disk_used_bytes{folder="download"}) / max(sabnzbd_disk_total_bytes{folder="download"})', unit="percentunit",
           thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 0.85}, {"color": "red", "value": 0.95}])
    b.ts("Download speed", [('max(sabnzbd_speed_bps)', "speed")], unit="Bps", w=8)
    b.ts("Remaining in queue", [('max(sabnzbd_remaining_bytes)', "remaining"), ('max(sabnzbd_time_estimate_seconds)', "ETA (s)")], unit="bytes", w=8)
    b.ts("Article success by news server", [
        ('sum by (server) (increase(sabnzbd_server_articles_success[1h])) / sum by (server) (increase(sabnzbd_server_articles_total[1h]))', "{{server}}"),
    ], unit="percentunit", w=8, desc="share of articles fetched successfully (missing articles = incomplete downloads)")


def bazarr_panels(b: Board, s: Svc):
    b.stat("API reachable", 'max(bazarr_system_status)', mappings=UPDOWN, thresholds=[{"color": "red", "value": None}, {"color": "green", "value": 1}])
    b.stat("Health issues", 'sum(bazarr_system_health_issues) or vector(0)', thresholds=RED_IF_ABOVE_0)
    b.ts("Missing subtitles", [('sum(bazarr_subtitles_missing_total)', "episodes"), ('sum(bazarr_movie_subtitles_missing_total)', "movies")], w=12)
    b.ts("Subtitles downloaded", [('sum(bazarr_subtitles_downloaded_total)', "episodes"), ('sum(bazarr_movie_subtitles_downloaded_total)', "movies")], w=12)


def gpu_panels(b: Board, s: Svc):
    """nvidia_gpu_exporter on omen-worker1 (nvidia-device-plugin/gpu-exporter.yaml)."""
    b.stat("GPU utilisation", 'max(nvidia_smi_utilization_gpu_ratio)', unit="percentunit")
    b.stat("GPU memory used", 'max(nvidia_smi_memory_used_bytes) / max(nvidia_smi_memory_total_bytes)', unit="percentunit",
           thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 0.9}])
    b.stat("Temperature", 'max(nvidia_smi_temperature_gpu)', unit="celsius",
           thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 75}, {"color": "red", "value": 85}])
    b.stat("Exporter collecting", 'min(nvidia_smi_last_collect_success)', mappings=UPDOWN,
           thresholds=[{"color": "red", "value": None}, {"color": "green", "value": 1}], desc="nvidia-smi answered on the last scrape")
    b.ts("Utilisation", [('max(nvidia_smi_utilization_gpu_ratio)', "GPU"), ('max(nvidia_smi_utilization_memory_ratio)', "memory controller")], unit="percentunit", w=8)
    b.ts("Memory", [('max(nvidia_smi_memory_used_bytes)', "used"), ('max(nvidia_smi_memory_total_bytes)', "total")], unit="bytes", w=8)
    b.ts("Temperature / power", [('max(nvidia_smi_temperature_gpu)', "°C"), ('max(nvidia_smi_power_draw_watts)', "W"),
                                 ('max(nvidia_smi_enforced_power_limit_watts)', "W limit")], w=8)
    b.ts("GPU jobs (pods holding the GPU)", [
        ('count by (namespace, pod) (kube_pod_container_resource_requests{resource="nvidia_com_gpu"} and on (namespace, pod) (kube_pod_status_phase{phase="Running"} == 1))', "{{namespace}}/{{pod}}"),
    ], w=24, bars=True, desc="Running pods that requested nvidia.com/gpu (one GPU: one job at a time)")


def external_dns_panels(b: Board, s: Svc):
    b.stat("Since last sync", 'time() - max(external_dns_controller_last_sync_timestamp_seconds)', unit="s",
           thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 300}, {"color": "red", "value": 900}],
           desc="runs every minute (--interval=1m)")
    b.stat("Errors (1h)", 'sum(increase(external_dns_registry_errors_total[1h])) + sum(increase(external_dns_source_errors_total[1h]))',
           thresholds=RED_IF_ABOVE_0, decimals=0, desc="Route 53 (registry) and Kubernetes (source) errors")
    b.stat("Records managed", 'sum(external_dns_registry_records)')
    b.ts("Errors", [('sum(increase(external_dns_registry_errors_total[$__rate_interval])) or vector(0)', "registry (Route 53)"),
                    ('sum(increase(external_dns_source_errors_total[$__rate_interval])) or vector(0)', "source (Kubernetes)")], bars=True, w=12)
    b.ts("Endpoints", [('sum(external_dns_source_endpoints_total)', "wanted (source)"), ('sum(external_dns_registry_endpoints_total)', "in Route 53")], w=12)


def homeassistant_panels(b: Board, s: Svc):
    """HA's prometheus integration (managed/packages/prometheus.yaml), entity states."""
    b.stat("Entities unavailable", 'count(hass_entity_available == 0) or vector(0)',
           desc="entities HA marks unavailable. ~90 are always unavailable (Dreame options the vacuum lacks, iPhone sensors, ...); a jump means an integration or device went down")
    b.stat("Batteries below 20%", 'count(hass_sensor_battery_percent < 20) or vector(0)', thresholds=RED_IF_ABOVE_0)
    b.stat("Thermostat: actual", 'max(hass_climate_current_temperature_celsius)', unit="celsius", decimals=1)
    b.stat("Thermostat: target", 'max(hass_climate_target_temperature_celsius)', unit="celsius", decimals=1,
           desc="the setpoint HA sees; if the thermostat itself shows another one, see the Daikin note (hspActive vs hspHome)")
    b.ts("Thermostat", [('max by (friendly_name) (hass_climate_current_temperature_celsius)', "{{friendly_name}} actual"),
                        ('max by (friendly_name) (hass_climate_target_temperature_celsius)', "{{friendly_name}} target")], unit="celsius", w=12)
    b.ts("Temperatures", [('max by (friendly_name) (hass_sensor_temperature_celsius)', "{{friendly_name}}")], unit="celsius", w=12)
    b.ts("Humidity", [('max by (friendly_name) (hass_sensor_humidity_percent)', "{{friendly_name}}")], unit="percent", w=8)
    b.ts("Power", [('max by (friendly_name) (hass_sensor_power_w)', "{{friendly_name}}")], unit="watt", w=8)
    b.table("Lowest batteries", [('bottomk(10, max by (friendly_name) (hass_sensor_battery_percent))', "")], w=8,
            transformations=[{"id": "organize", "options": {"excludeByName": {"Time": True}, "renameByName": {"Value": "%"}}}])
    b.table("Unavailable entities", [('max by (entity, friendly_name, domain) (hass_entity_available == 0)', "")], w=24,
            transformations=[{"id": "organize", "options": {"excludeByName": {"Time": True, "Value": True}}}])


def adguard_panels(b: Board, s: Svc):
    # query stats from adguard-exporter (observability/exporters/adguard-exporter.yaml); AdGuard
    # reports them over its statistics window (24h), so these are gauges, not counters
    b.stat("Protection", 'max(adguard_protection_enabled)',
           mappings=[{"type": "value", "options": {"0": {"text": "OFF", "color": "red"}, "1": {"text": "on", "color": "green"}}}],
           desc="filtering on/off (the AdGuard UI toggle)")
    b.stat("Queries (24h)", 'max(adguard_queries)')
    b.stat("Blocked (24h)", 'max(adguard_queries_blocked) / max(adguard_queries)', unit="percentunit", decimals=1)
    b.stat("Avg processing time", 'max(adguard_avg_processing_time_seconds)', unit="s",
           thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 0.1}, {"color": "red", "value": 0.5}])
    b.ts("Upstream response time", [('max by (upstream) (adguard_top_upstreams_avg_response_time_seconds)', "{{upstream}}")], unit="s", w=12)
    b.ts("Queries / blocked (24h window)", [('max(adguard_queries)', "queries"), ('max(adguard_queries_blocked)', "blocked")], w=12)
    b.table("Top clients (24h)", [('topk(10, max by (name) (adguard_top_clients))', "")], w=8,
            transformations=[{"id": "organize", "options": {"excludeByName": {"Time": True}, "renameByName": {"Value": "queries"}}}],
            desc="10.244.0.1 / 10.244.1.1 = pods in the cluster (node gateway)")
    b.table("Top blocked domains (24h)", [('topk(10, max by (domain) (adguard_top_blocked_domains))', "")], w=8,
            transformations=[{"id": "organize", "options": {"excludeByName": {"Time": True}, "renameByName": {"Value": "queries"}}}])
    b.table("Top queried domains (24h)", [('topk(10, max by (domain) (adguard_top_queried_domains))', "")], w=8,
            transformations=[{"id": "organize", "options": {"excludeByName": {"Time": True}, "renameByName": {"Value": "queries"}}}])
    b.ts("Probes: LAN DNS (10.0.0.71:53) and web UI", [('min by (instance) (probe_success{probe="internal", target_namespace="adguard-home"})', "{{instance}}")],
         desc="1 = up, 0 = down. dns_a = resolves github.com through the LoadBalancer IP the LAN uses; 0 = LAN DNS is broken")
    b.ts("Upstream failures by upstream", [(f'sum by (upstream) (count_over_time({loki_sel(s)} |= "exchange failed" | regexp "upstream=(?P<upstream>[^ ]+)" [$__auto])) or vector(0)', "{{upstream}}")],
         ds=LOKI, bars=True, desc="queries AdGuard could not forward; with parallel upstreams a single failing upstream is harmless, all failing = DNS outage")


def agent_panels(b: Board, s: Svc):
    yes_no = [{"type": "value", "options": {"0": {"text": "NO", "color": "red"}, "1": {"text": "YES", "color": "green"}}}]
    b.row("Agent health")
    b.stat("Claude signed in", "max(homelab_agent_signed_in)", mappings=yes_no,
           thresholds=[{"color": "red", "value": None}, {"color": "green", "value": 1}],
           desc="If NO: sign in at https://agent.tkuipers.ca/#/auth")
    b.stat("Parts down", 'count(homelab_agent_component_up == 0) or vector(0)', thresholds=RED_IF_ABOVE_0,
           desc="Agent parts failing their health check (see the timeline below)")
    b.stat("MCP servers down", 'count(homelab_agent_mcp_up == 0) or vector(0)', thresholds=RED_IF_ABOVE_0)
    b.stat("Working now", "max(homelab_agent_busy)", desc="Conversations executing right now")
    b.stat("Oldest queued", "max(homelab_agent_oldest_queued_seconds)", unit="s",
           thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 600}, {"color": "red", "value": 1800}])
    b.stat("Last daily scan", "time() - max(homelab_agent_last_scan_timestamp_seconds)", unit="s",
           thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 26 * 3600}, {"color": "red", "value": 30 * 3600}])
    b.timeline("Agent parts (up / down over time)", [("max by (component) (homelab_agent_component_up)", "{{component}}")], h=7,
               desc="claude = signed in; database = Postgres reachable; egress_proxy; ssh_keys = git auth + signing keys loaded; sms; jev; homelab_repo; scheduler")
    b.row("MCP servers")
    b.timeline("MCP servers (up / down over time)", [("max by (server) (homelab_agent_mcp_up)", "{{server}}")], h=7,
               desc="Each enabled MCP server is probed every 5 minutes: connect and list its tools. Edit servers at https://agent.tkuipers.ca/#/mcp")
    b.table("MCP servers now", [
        ("max by (server) (homelab_agent_mcp_up)", ""),
        ("max by (server) (homelab_agent_mcp_tools)", ""),
        ("max by (server) (homelab_agent_mcp_probe_seconds)", ""),
    ], w=12, transformations=[
        {"id": "merge", "options": {}},
        {"id": "organize", "options": {"excludeByName": {"Time": True},
                                       "renameByName": {"Value #A": "Up", "Value #B": "Tools", "Value #C": "Probe (s)", "server": "Server"}}},
    ], overrides=[{"matcher": {"id": "byName", "options": "Up"}, "properties": [
        {"id": "mappings", "value": [{"type": "value", "options": {"0": {"text": "DOWN", "color": "red"}, "1": {"text": "UP", "color": "green"}}}]},
        {"id": "custom.cellOptions", "value": {"type": "color-background"}}]}])
    b.ts("MCP connect failures at run start", [("sum by (server) (increase(homelab_agent_mcp_connect_failures_total[$__rate_interval]))", "{{server}}")], w=12, bars=True)
    b.ts("MCP probe latency", [("max by (server) (homelab_agent_mcp_probe_seconds)", "{{server}}")], unit="s", w=12)
    b.row("Activity")
    b.ts("Conversations started", [("sum by (kind) (increase(homelab_agent_runs_total[$__rate_interval]))", "{{kind}}")], bars=True)
    b.ts("Outcomes", [("sum by (outcome) (increase(homelab_agent_run_outcomes_total[$__rate_interval]))", "{{outcome}}")], bars=True)
    b.ts("Claude usage (USD equivalent)", [("sum by (kind) (increase(homelab_agent_cost_usd_total[$__rate_interval]))", "{{kind}}")], bars=True,
         desc="Estimated from Claude Code's own accounting; on a subscription this is not billed per token")
    b.ts("Texts", [("sum by (direction) (increase(homelab_agent_sms_total[$__rate_interval]))", "{{direction}}")], bars=True)
    b.ts("Routing", [("sum by (method, result) (increase(homelab_agent_route_decisions_total[$__rate_interval]))", "{{method}} -> {{result}}"),
                     ("sum(increase(homelab_agent_route_corrections_total[$__rate_interval]))", "moved by Tyler (misroute)")], bars=True,
         desc="How incoming texts were routed. 'moved by Tyler' = he corrected a route with a bare #N: tune ROUTE_MIN_* if it grows")
    b.ts("Top tools", [("topk(8, sum by (tool) (increase(homelab_agent_tool_calls_total[$__rate_interval])))", "{{tool}}")], bars=True)
    b.ts("Database write errors", [("sum(increase(homelab_agent_db_write_errors_total[$__rate_interval])) or vector(0)", "errors")], bars=True)


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
    b.ts("Tempo spans discarded / s", [('sum by (reason) (rate(tempo_discarded_spans_total[$__rate_interval])) or vector(0)', "{{reason}}")],
         desc="the trace pipeline in detail: Beyla dashboard")


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
    S("homeassistant", "homeassistant", "Home Assistant", ingress=["homeassistant"], probe="homeassistant", folder="Home Assistant",
      extras=[homeassistant_panels]),
    S("homeassistant", "hamh", "Home Assistant Matter Hub (hamh)", ingress=["hamh"], probe="hamh", folder="Home Assistant"),
    S("homeassistant", "matter-server", "Matter server", folder="Home Assistant"),
    S("homelab-agent", "homelab-agent", "Homelab agent", ingress=["homelab-agent"], probe="homelab-agent", folder="Apps",
      extras=[agent_panels], description="Claude Code agent: daily scans, alert response, SMS. https://agent.tkuipers.ca"),
    S("homelab-agent", "homelab-agent-relay", "Homelab agent SMS relay", probe="homelab-agent-relay", folder="Apps", quiet=True),
    S("homelab-agent", "homelab-agent-postgres", "Homelab agent Postgres", folder="Apps", extras=[postgres_panels]),
    S("homelab-agent", "homelab-agent-postgres-backup", "Homelab agent Postgres backup (CronJob)", kind="cronjob", folder="Apps"),
    S("homepage", "homepage", "Homepage (tkuipers.ca)", ingress=["homepage", "resume-proxy"], probe="homepage", access_logs=True, folder="Apps",
      extras=[browser_panels]),

    S("mediacenter", "jellyfin", "Jellyfin", ingress=["jellyfin"], probe="jellyfin", folder="Media", extras=[jellyfin_panels]),
    S("mediacenter", "jellyseerr", "Jellyseerr", ingress=["jellyseerr"], probe="jellyseerr", folder="Media"),
    S("mediacenter", "sonarr", "Sonarr", ingress=["sonarr"], probe="sonarr", folder="Media", extras=[arr("sonarr")]),
    S("mediacenter", "radarr", "Radarr", ingress=["radarr"], probe="radarr", folder="Media", extras=[arr("radarr")]),
    S("mediacenter", "readarr", "Readarr", ingress=["readarr"], probe="readarr", folder="Media", extras=[arr("readarr")]),
    S("mediacenter", "prowlarr", "Prowlarr", ingress=["prowlarr"], probe="prowlarr", folder="Media", extras=[arr("prowlarr")]),
    S("mediacenter", "bazarr", "Bazarr", ingress=["bazarr"], probe="bazarr", folder="Media", extras=[bazarr_panels]),
    S("mediacenter", "kavita", "Kavita", ingress=["kavita"], probe="kavita", folder="Media"),
    S("mediacenter", "sabnzbd", "SABnzbd (+gluetun VPN)", ingress=["sabnzbd"], probe="sabnzbd", folder="Media", extras=[sabnzbd_panels]),
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
    S("stocks", "redis", "Stocks Redis", folder="Stocks", quiet=True, extras=[redis_panels]),
    S("stocks", "postgres-backup", "Stocks Postgres backup (CronJob)", kind="cronjob", folder="Stocks"),

    # --- infrastructure ----------------------------------------------------
    S("adguard-home", "adguard-home", "AdGuard Home (DNS)", ingress=["adguard-home"], probe="adguard-home", folder="Infrastructure", extras=[adguard_panels]),
    S("authelia", "authelia", "Authelia (SSO)", ingress=["authelia"], probe="authelia", folder="Infrastructure", extras=[authelia_panels]),
    S("authelia", "authelia-redis", "Authelia Redis", folder="Infrastructure", extras=[redis_panels]),
    S("aws-ip-updater", "aws-ip-updater", "AWS dynamic DNS updater (CronJob)", kind="cronjob", folder="Infrastructure"),
    S("cert-manager", "infrastructure-cert-manager", "cert-manager", folder="Infrastructure", extras=[cert_manager_panels]),
    S("cert-manager", "infrastructure-cert-manager-cainjector", "cert-manager cainjector", folder="Infrastructure"),
    S("cert-manager", "infrastructure-cert-manager-webhook", "cert-manager webhook", folder="Infrastructure"),
    S("nfs-provisioner", "csi-smb-controller", "CSI SMB controller", folder="Infrastructure", quiet=True),
    S("nfs-provisioner", "csi-smb-node", "CSI SMB node", kind="daemonset", folder="Infrastructure"),
    S("nfs-provisioner", "samba-server-dell-r620", "Samba server (dell-r620)", folder="Infrastructure", quiet=True),
    S("nfs-provisioner", "samba-server-omen-worker1", "Samba server (omen-worker1)", folder="Infrastructure", quiet=True),
    S("external-dns", "external-dns", "external-dns", folder="Infrastructure", extras=[external_dns_panels]),
    S("ingress-nginx", "infrastructure-ingress-nginx-controller", "Ingress NGINX", access_logs=True, probe="kubernetes-api-proxy", folder="Infrastructure",
      extras=[ingress_global], traces="ingress-nginx", description="All HTTP traffic into the cluster. Per-service views live in each service dashboard."),
    S("local-path-storage", "local-path-provisioner", "local-path provisioner", folder="Infrastructure", quiet=True),
    S("metallb-system", "infrastructure-metallb-controller", "MetalLB controller", folder="Infrastructure", extras=[metallb_panels]),
    S("metallb-system", "infrastructure-metallb-speaker", "MetalLB speaker", kind="daemonset", folder="Infrastructure"),
    S("nvidia-device-plugin", "nvidia-device-plugin", "NVIDIA device plugin", kind="daemonset", folder="Infrastructure", quiet=True),
    S("nvidia-device-plugin", "nvidia-gpu-exporter", "GPU (omen-worker1)", kind="daemonset", folder="Infrastructure", quiet=True, extras=[gpu_panels],
      description="GTX 1060 on omen-worker1, shared by the training jobs (nvidia_gpu_exporter)"),
    S("default", "external-secrets", "External Secrets Operator", folder="Infrastructure", extras=[eso_panels], quiet=True),
    S("default", "external-secrets-cert-controller", "External Secrets cert controller", folder="Infrastructure"),
    S("default", "external-secrets-webhook", "External Secrets webhook", folder="Infrastructure"),
    S("default", "op-connect", "1Password Connect", folder="Infrastructure"),

    S("argocd", "argocd-server", "Argo CD server", ingress=["argocd-server-ingress"], probe="argocd-server", folder="Argo CD", extras=[argocd_panels]),
    S("argocd", "argocd-application-controller", "Argo CD application controller", kind="statefulset", folder="Argo CD", traces="argocd-controller"),
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

    S("observability", "kps-grafana", "Grafana", ingress=["kps-grafana"], probe="grafana", folder="Observability", traces="grafana"),
    S("observability", "prometheus-kps", "Prometheus", kind="statefulset", folder="Observability", extras=[observability_panels]),
    S("observability", "loki", "Loki", kind="statefulset", folder="Observability"),
    S("observability", "tempo", "Tempo", kind="statefulset", folder="Observability"),
    S("observability", "alloy", "Alloy (node collector)", kind="daemonset", folder="Observability"),
    S("observability", "alloy-events", "Alloy (k8s events)", folder="Observability"),
    S("observability", "alloy-faro", "Alloy (Faro browser telemetry)", ingress=["alloy-faro"], probe="alloy-faro", folder="Observability",
      description="public receiver https://faro.tkuipers.ca/collect for tkuipers.ca's Grafana Faro Web SDK; the data is on the Homepage dashboard"),
    S("observability", "beyla", "Beyla (eBPF traces) + trace pipeline", kind="daemonset", folder="Observability", extras=[tracing_panels],
      description="eBPF auto-instrumentation for third-party apps (helm-chart-beyla), and the whole trace pipeline: senders -> Alloy -> Tempo"),
    S("observability", "alertmanager-kps", "Alertmanager", kind="statefulset", folder="Observability"),
    S("observability", "kps-kube-state-metrics", "kube-state-metrics", folder="Observability"),
    S("observability", "kps-prometheus-node-exporter", "node-exporter", kind="daemonset", folder="Observability", extras=[node_panels]),
    S("observability", "kps-operator", "Prometheus operator", folder="Observability"),
    S("observability", "blackbox", "Blackbox exporter (probes)", folder="Observability", extras=[blackbox_panels]),
]


# ----------------------------------------------------------------------------
# Overview dashboards
# ----------------------------------------------------------------------------

# Problem counts per platform area (0 = OK). Shared by the area tiles and the
# "Platform status" roll-up, so they can never disagree.
AREAS = [
    # (title, PromQL counting failing things, description)
    ("Apps", 'count(probe_success{probe="internal"} == 0)',
     "in-cluster health checks of the apps themselves (incl. LAN DNS) that fail"),
    ("Public URLs", 'count(probe_success{probe="external"} == 0)',
     "public *.tkuipers.ca hosts that fail (DNS / ingress / TLS / Authelia)"),
    ("Workloads",
     '(count(kube_deployment_status_replicas_available - kube_deployment_spec_replicas < 0) or vector(0))'
     ' + (count(kube_statefulset_status_replicas_ready - kube_statefulset_replicas < 0) or vector(0))'
     ' + (count(kube_daemonset_status_number_ready - kube_daemonset_status_desired_number_scheduled < 0) or vector(0))'
     ' + (count(kube_pod_container_status_waiting_reason{reason=~"CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerConfigError"}) or vector(0))',
     "deployments / statefulsets / daemonsets missing ready pods + crash-looping containers"),
    ("Nodes",
     '(count(kube_node_status_condition{condition="Ready", status="true"} == 0) or vector(0))'
     ' + (count(kube_node_status_condition{condition=~"MemoryPressure|DiskPressure|PIDPressure", status="true"} == 1) or vector(0))',
     "nodes not Ready or under memory / disk / PID pressure"),
    ("Disks",
     'count(max by (instance, mountpoint) (1 - node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs"}) > 0.85)',
     "node filesystems more than 85% full"),
    ("Certificates",
     '(count(min by (instance) (probe_ssl_earliest_cert_expiry - time()) < 14 * 86400) or vector(0))'
     ' + (count(certmanager_certificate_ready_status{condition="False"} == 1) or vector(0))',
     "public certificates expiring within 14 days + cert-manager certificates not Ready"),
    ("Cron jobs",
     '(count(((time() - max by (namespace, cronjob) (kube_cronjob_status_last_successful_time)) - 2 * (max by (namespace, cronjob) (kube_cronjob_next_schedule_time) - max by (namespace, cronjob) (kube_cronjob_status_last_schedule_time)) - 1800) > 0 unless on (namespace, cronjob) (kube_cronjob_spec_suspend == 1)) or vector(0))'
     ' + (count(max by (namespace, job_name) (kube_job_status_failed > 0) and on (namespace, job_name) (time() - kube_job_status_start_time < 86400)) or vector(0))',
     "CronJobs overdue (incl. backups) + Jobs that failed in the last 24h"),
    ("Argo CD", 'count(argocd_app_info{sync_status!="Synced"} or argocd_app_info{health_status!="Healthy"})',
     "Argo CD applications not Synced or not Healthy"),
    ("Secrets", 'count(externalsecret_status_condition{condition="Ready", status="False"} == 1)',
     "ExternalSecrets that cannot sync from 1Password"),
    ("Monitoring",
     '(count(up == 0) or vector(0))'
     ' + (sum(rate(otelcol_exporter_sent_log_records_total{component_id="otelcol.exporter.otlphttp.loki"}[5m])) < bool 0.01 or vector(1))'
     ' + (sum(rate(grafana_alerting_rule_evaluations_total[10m])) < bool 0.001 or vector(1))'
     ' + (count(count by (job) (up{job=~"kube-state-metrics|node-exporter|blackbox|argocd-metrics|infrastructure-cert-manager|observability/external-secrets|infrastructure-ingress-nginx-controller-metrics|kubelet"} == 1)) < bool 8 or vector(1))',
     "the monitoring itself: scrape targets down + logs not shipping + Grafana not evaluating alert rules"
     " + a core exporter missing entirely (its tiles would otherwise read OK for lack of data)"),
    ("5xx rate",
     '(sum(rate(nginx_ingress_controller_requests{status=~"5.."}[15m])) / sum(rate(nginx_ingress_controller_requests[15m])) > bool 0.05) or vector(0)',
     "1 when more than 5% of all requests through ingress-nginx were answered with 5xx in the last 15m"),
]
OK_MAP = [{"type": "value", "options": {"0": {"text": "OK", "color": "green"}}}]


def master() -> Board:
    b = Board("platform-health", "Platform health", ["homelab", "overview"], "Overview", time_from="now-24h",
              description="Home dashboard: is the platform green? Every tile is a count of failing things (OK = 0). "
                          "For details go to Homelab overview or the service dashboards.")
    b.editable = False  # generated; the home copy cannot be saved anyway
    # ---- one answer ---------------------------------------------------------
    rollup = " + ".join(f"clamp_max(({q}) or vector(0), 1)" for _, q, _ in AREAS)
    b.stat("Platform status", rollup, w=16, h=5, unit="suffix: area(s) need attention",
           thresholds=RED_IF_ABOVE_0, desc="number of the 11 coloured areas below that are not OK (firing alerts and error logs are shown separately)",
           mappings=[{"type": "value", "options": {"0": {"text": "ALL GREEN", "color": "green"}}}])
    b.stat("Firing alerts",
           '(count(ALERTS{alertstate="firing", alertname!~"Watchdog|InfoInhibitor"}) or vector(0)) + (sum(grafana_alerting_alerts{state="alerting"}) or vector(0))',
           w=8, h=5, thresholds=ORANGE_RED, mappings=OK_MAP,
           desc="Grafana-managed + Prometheus alerts currently firing (list below)")
    # ---- one tile per area --------------------------------------------------
    for title, q, desc in AREAS:
        b.stat(title, f"({q}) or vector(0)", w=4, h=4, thresholds=RED_IF_ABOVE_0, mappings=OK_MAP, desc=desc + ". 0 = OK")
    b.stat("Error logs",
           'count(sum by (k8s_namespace_name, service_name) (count_over_time({k8s_namespace_name=~".+", service_name!="kubernetes-events"} | detected_level=~"error|fatal|critical" [1h])) > 20) or vector(0)',
           ds=LOKI, w=4, h=4, thresholds=[{"color": "text", "value": None}], mappings=[{"type": "value", "options": {"0": {"text": "none"}}}],
           desc="informational, not part of the status: services that logged more than 20 error lines in the last hour (alert 'Errors logged steadily' fires after 2h)")
    # ---- what and since when -----------------------------------------------
    b.alertlist("Firing & pending alerts", w=14, h=9, label_filter='{severity!="none"}')
    b.ts("Problems over time", [
        (rollup, "areas needing attention"),
        ('count(probe_success == 0) or vector(0)', "failing probes"),
        ('(count(kube_deployment_status_replicas_available - kube_deployment_spec_replicas < 0) or vector(0)) + (count(kube_statefulset_status_replicas_ready - kube_statefulset_replicas < 0) or vector(0)) + (count(kube_daemonset_status_number_ready - kube_daemonset_status_desired_number_scheduled < 0) or vector(0))', "workloads not ready"),
        ('(count(ALERTS{alertstate="firing", alertname!~"Watchdog|InfoInhibitor"}) or vector(0)) + (sum(grafana_alerting_alerts{state="alerting"}) or vector(0))', "firing alerts"),
    ], w=10, h=9, desc="when did it start? (24h)")
    b.text("", "Details: **[Homelab overview](/d/homelab-overview)** (incident start page) · "
               "**[All dashboards](/dashboards)** · **[Alert rules](/alerting/list)** · "
               "**[Explore logs](/a/grafana-lokiexplore-app/explore)**", h=2)
    return b


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
    boards = [master(), overview()] + [namespace_overview(*x) for x in NAMESPACE_OVERVIEWS] + [standard(s) for s in CATALOG]
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
