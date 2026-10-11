#!/usr/bin/env python3
"""
Run every query of every panel of every provisioned dashboard through the
Grafana API and report panels that return no data or fail.

    kubectl -n observability port-forward svc/kps-grafana 13000:80 &
    GRAFANA_URL=http://localhost:13000 GRAFANA_AUTH=admin:<password> \
        python3 tooling/observability/verify_dashboards.py [--tag service] [--json out.json]

GRAFANA_TOKEN=<service account token> can be used instead of GRAFANA_AUTH.
Exit code 1 if any panel has no data / errors.
"""
import argparse
import base64
import json
import os
import re
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor

URL = os.environ.get("GRAFANA_URL", "http://localhost:13000").rstrip("/")


def headers():
    h = {"Content-Type": "application/json"}
    if os.environ.get("GRAFANA_TOKEN"):
        h["Authorization"] = "Bearer " + os.environ["GRAFANA_TOKEN"]
    elif os.environ.get("GRAFANA_AUTH"):
        h["Authorization"] = "Basic " + base64.b64encode(os.environ["GRAFANA_AUTH"].encode()).decode()
    return h


def call(path, body=None):
    req = urllib.request.Request(URL + path, data=json.dumps(body).encode() if body is not None else None,
                                 headers=headers(), method="POST" if body is not None else "GET")
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        return {"__error__": f"HTTP {e.code}: {e.read()[:300].decode(errors='replace')}"}


SUBST = {
    "$__rate_interval": "2m", "$__auto": "5m", "$__interval": "1m", "${__interval}": "1m",
    "$level": ".*", "$search": "",
}


def interpolate(expr):
    for k, v in SUBST.items():
        expr = expr.replace(k, v)
    return expr


def rel_to_ms(spec):
    m = re.fullmatch(r"(?:now-)?(\d+)([smhdw])", spec)
    n, u = int(m.group(1)), m.group(2)
    return n * {"s": 1, "m": 60, "h": 3600, "d": 86400, "w": 604800}[u] * 1000


def check_panel(dash, panel):
    targets = [t for t in panel.get("targets", []) if t.get("expr")]
    if not targets:
        return None
    rng = panel.get("timeFrom") or dash["time"]["from"]
    frm = f"now-{rel_to_ms(rng)//1000}s"
    queries = []
    for t in targets:
        q = dict(t)
        q["expr"] = interpolate(q["expr"])
        q["datasource"] = t.get("datasource") or panel.get("datasource")
        q["intervalMs"] = 60000
        q["maxDataPoints"] = 200
        if panel["type"] == "logs":
            q["maxLines"] = 5
        queries.append(q)
    res = call("/api/ds/query", {"from": frm, "to": "now", "queries": queries})
    if "__error__" in res:
        return ("ERROR", res["__error__"])
    rows, errors = 0, []
    for ref, r in res.get("results", {}).items():
        if r.get("error"):
            errors.append(f"{ref}: {r['error'][:200]}")
        for fr in r.get("frames", []):
            vals = fr.get("data", {}).get("values", [])
            if vals and vals[0]:
                rows += len(vals[0])
    if rows:
        return ("OK", rows)
    return ("ERROR" if errors else "NODATA", "; ".join(errors))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", default="homelab")
    ap.add_argument("--json")
    ap.add_argument("--only")
    a = ap.parse_args()
    found = call(f"/api/search?type=dash-db&tag={a.tag}&limit=5000")
    if isinstance(found, dict) and "__error__" in found:
        sys.exit(found["__error__"])
    jobs = []
    for d in found:
        if a.only and a.only not in d["uid"]:
            continue
        dash = call(f"/api/dashboards/uid/{d['uid']}")["dashboard"]
        for p in dash.get("panels", []):
            for pp in [p] + p.get("panels", []):
                jobs.append((dash, pp))
    results = []
    with ThreadPoolExecutor(8) as ex:
        for (dash, p), r in zip(jobs, ex.map(lambda j: check_panel(*j), jobs)):
            if r:
                results.append({"dashboard": dash["title"], "uid": dash["uid"], "panel": p.get("title"),
                                "type": p["type"], "status": r[0], "detail": r[1]})
    bad = [r for r in results if r["status"] != "OK"]
    for r in bad:
        print(f"{r['status']:7} {r['dashboard']} :: {r['panel']} ({r['type']}) {r['detail'] if r['status'] == 'ERROR' else ''}")
    print(f"\n{len(found)} dashboards, {len(results)} panels with queries, {len(results) - len(bad)} OK, {len(bad)} without data/errors")
    if a.json:
        json.dump(results, open(a.json, "w"), indent=1)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
