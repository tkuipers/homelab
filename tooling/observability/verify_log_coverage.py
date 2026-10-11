#!/usr/bin/env python3
"""
Check that every container in the cluster has its logs in Loki.

For every container (incl. init containers) of every pod kubelet still knows
about, read the newest log line straight from kubelet (`kubectl logs
--timestamps --tail=1`) and check Loki has lines for that
namespace/pod/container:

    OK       Loki has lines
    MISSING  kubelet has a line inside Loki's retention, Loki has nothing  <- bug
    SILENT   the container's newest line is older than retention / it never logged /
             kubelet no longer has its logs (dead container)
    PENDING  newest line is < 2 min old and not in Loki yet (shipping delay)

    kubectl -n observability port-forward svc/loki 13100:3100 &
    LOKI_URL=http://localhost:13100 python3 tooling/observability/verify_log_coverage.py

Exit code 1 if anything is MISSING.
"""
import datetime as dt
import json
import os
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

LOKI = os.environ.get("LOKI_URL", "http://localhost:13100").rstrip("/")
RETENTION = dt.timedelta(days=int(os.environ.get("RETENTION_DAYS", "29")))


def kubectl(*args):
    return subprocess.run(["kubectl", *args], capture_output=True, text=True, timeout=60)


def last_log_time(ns, pod, container):
    r = kubectl("-n", ns, "logs", pod, "-c", container, "--timestamps", "--tail=1")
    line = r.stdout.strip().splitlines()
    if r.returncode != 0:
        return "unavailable"
    if not line:
        return None
    ts = line[-1].split(" ", 1)[0]
    try:
        return dt.datetime.fromisoformat(ts.replace("Z", "+00:00")[:26] + "+00:00" if "." in ts else ts.replace("Z", "+00:00"))
    except ValueError:
        return None


def loki_count(ns, pod, container):
    q = f'sum(count_over_time({{k8s_namespace_name="{ns}", k8s_pod_name="{pod}", k8s_container_name="{container}"}}[30d]))'
    url = f"{LOKI}/loki/api/v1/query?" + urllib.parse.urlencode({"query": q})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(url, timeout=120) as r:
                res = json.load(r)["data"]["result"]
            return int(float(res[0]["value"][1])) if res else 0
        except Exception:
            if attempt == 4:
                raise
            time.sleep(10)


def check(item):
    ns, pod, c = item
    now = dt.datetime.now(dt.timezone.utc)
    last = last_log_time(ns, pod, c)
    if last is None:
        return (*item, "SILENT", "never logged anything")
    if last == "unavailable":
        return (*item, "SILENT", "kubelet has no logs for it (container gone)")
    if now - last > RETENTION:
        return (*item, "SILENT", f"newest line {last:%Y-%m-%d}")
    n = loki_count(ns, pod, c)
    if n:
        return (*item, "OK", f"{n} lines")
    if now - last < dt.timedelta(minutes=2):
        return (*item, "PENDING", f"newest line {last:%H:%M:%S}")
    return (*item, "MISSING", f"newest line {last:%Y-%m-%d %H:%M}")


def main():
    pods = json.loads(kubectl("get", "pods", "-A", "-o", "json").stdout)["items"]
    items = []
    for p in pods:
        if p["status"].get("phase") == "Pending":
            continue
        for c in p["spec"].get("initContainers", []) + p["spec"]["containers"]:
            items.append((p["metadata"]["namespace"], p["metadata"]["name"], c["name"]))
    with ThreadPoolExecutor(8) as ex:
        results = list(ex.map(check, items))
    order = {"MISSING": 0, "PENDING": 1, "SILENT": 2, "OK": 3}
    for r in sorted(results, key=lambda r: (order[r[3]], r[0], r[1])):
        if r[3] != "OK" or "-v" in sys.argv:
            print(f"{r[3]:8} {r[0]}/{r[1]} [{r[2]}] {r[4]}")
    counts = {k: sum(1 for r in results if r[3] == k) for k in order}
    print(f"\n{len(results)} containers: " + ", ".join(f"{k} {v}" for k, v in counts.items()))
    sys.exit(1 if counts["MISSING"] else 0)


if __name__ == "__main__":
    main()
