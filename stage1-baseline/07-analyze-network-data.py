#!/usr/bin/env python3
"""
Analyze bursty load + network telemetry outputs.

Generates:
1) pod to node placement mappings and movement
2) e2e latency stats from fortio runs
3) service-to-service latency stats from curl probes
4) extra suggested metrics for network-aware pod placement experiments
"""

import argparse
import json
import math
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple


def percentile(values: List[float], q: float) -> Optional[float]:
    if not values:
        return None
    if len(values) == 1:
        return values[0]
    pos = (len(values) - 1) * (q / 100.0)
    low = int(math.floor(pos))
    high = int(math.ceil(pos))
    if low == high:
        return values[low]
    weight = pos - low
    return values[low] * (1 - weight) + values[high] * weight


def safe_mean(values: List[float]) -> Optional[float]:
    if not values:
        return None
    return statistics.fmean(values)


def format_ms(v: Optional[float]) -> str:
    if v is None:
        return "n/a"
    return f"{v:.2f} ms"


def load_json(path: Path) -> Optional[dict]:
    try:
        return json.loads(path.read_text())
    except Exception:
        return None


def detect_timestamp_from_name(path: Path, prefix: str) -> str:
    stem = path.stem
    if stem.startswith(prefix):
        return stem[len(prefix):]
    return "unknown"


def load_pod_snapshots(network_dir: Path) -> List[dict]:
    snapshots = []
    for p in sorted(network_dir.glob("pod-network-*.json")):
        payload = load_json(p)
        if not payload:
            continue
        timestamp = detect_timestamp_from_name(p, "pod-network-")
        snapshots.append(
            {
                "timestamp": timestamp,
                "items": payload.get("items", []),
            }
        )
    return snapshots


def load_service_endpoint_nodes(network_dir: Path) -> Dict[str, Set[str]]:
    service_to_nodes: Dict[str, Set[str]] = defaultdict(set)
    for p in sorted(network_dir.glob("service-endpoints-*.json")):
        payload = load_json(p)
        if not payload:
            continue
        for item in payload.get("items", []):
            service_name = (item.get("metadata") or {}).get("name", "unknown")
            for subset in item.get("subsets", []) or []:
                for addr in subset.get("addresses", []) or []:
                    node_name = addr.get("nodeName")
                    if node_name:
                        service_to_nodes[service_name].add(node_name)
    return service_to_nodes


def summarize_pod_placement(pod_snapshots: List[dict]) -> dict:
    pod_history = defaultdict(list)
    ts_node_to_pods = {}

    for snap in pod_snapshots:
        ts = snap["timestamp"]
        node_to_pods = defaultdict(list)
        for pod in snap["items"]:
            md = pod.get("metadata", {})
            spec = pod.get("spec", {})
            labels = md.get("labels", {})

            pod_name = md.get("name", "unknown")
            app = labels.get("app", "unknown")
            node = spec.get("nodeName", "unknown")

            pod_history[pod_name].append({"timestamp": ts, "node": node, "app": app})
            node_to_pods[node].append(pod_name)
        ts_node_to_pods[ts] = node_to_pods

    pod_movements = {}
    for pod_name, entries in pod_history.items():
        nodes = [e["node"] for e in entries]
        unique = sorted(set(nodes))
        if len(unique) > 1:
            pod_movements[pod_name] = entries

    latest_ts = sorted(ts_node_to_pods.keys())[-1] if ts_node_to_pods else None
    latest = ts_node_to_pods.get(latest_ts, {})

    # Service -> node -> pod count from **latest snapshot only** (actual current placement)
    latest_snap = next((s for s in pod_snapshots if s["timestamp"] == latest_ts), None)
    service_node_spread = {}
    if latest_snap:
        service_node_counter_latest: Dict[str, Counter] = defaultdict(Counter)
        for pod in latest_snap["items"]:
            app = (pod.get("metadata") or {}).get("labels", {}).get("app", "unknown")
            node = (pod.get("spec") or {}).get("nodeName", "unknown")
            if node and node != "unknown":
                service_node_counter_latest[app][node] += 1
        for svc, counter in service_node_counter_latest.items():
            service_node_spread[svc] = {
                "nodes_used": sorted(counter.keys()),
                "node_count": len(counter),
                "pod_count_by_node": dict(counter),
            }

    # Service -> node -> average pod count over all snapshots (for heatmap "average snapshot")
    service_node_spread_avg: Dict[str, dict] = {}
    if pod_snapshots:
        all_services_avg: Set[str] = set()
        all_nodes_avg: Set[str] = set()
        per_snap: List[Dict[str, Dict[str, int]]] = []
        for snap in pod_snapshots:
            counter: Dict[str, Counter] = defaultdict(Counter)
            for pod in snap["items"]:
                app = (pod.get("metadata") or {}).get("labels", {}).get("app", "unknown")
                node = (pod.get("spec") or {}).get("nodeName", "unknown")
                if node and node != "unknown":
                    counter[app][node] += 1
                    all_services_avg.add(app)
                    all_nodes_avg.add(node)
            per_snap.append({svc: dict(ct) for svc, ct in counter.items()})
        n_snapshots = len(pod_snapshots)
        for svc in sorted(all_services_avg):
            pod_count_by_node_avg = {}
            for node in sorted(all_nodes_avg):
                total = sum(snap.get(svc, {}).get(node, 0) for snap in per_snap)
                pod_count_by_node_avg[node] = round(total / n_snapshots, 2)
            service_node_spread_avg[svc] = {
                "nodes_used": sorted(all_nodes_avg),
                "node_count": len(all_nodes_avg),
                "pod_count_by_node": pod_count_by_node_avg,
            }

    return {
        "latest_timestamp": latest_ts,
        "latest_node_to_pods": {k: sorted(v) for k, v in latest.items()},
        "pod_movements": pod_movements,
        "service_node_spread": service_node_spread,
        "service_node_spread_avg": service_node_spread_avg,
        "snapshot_count": len(pod_snapshots),
    }


def parse_fortio_percentiles(payload: dict) -> Dict[float, float]:
    hist = payload.get("DurationHistogram", {})
    rows = hist.get("Percentiles", []) or []
    out = {}
    for row in rows:
        try:
            out[float(row.get("Percentile"))] = float(row.get("Value")) * 1000.0
        except Exception:
            continue
    return out


def parse_endpoint_from_filename(name: str) -> str:
    # fortio-burst-<idx>-<endpoint>.json
    parts = name.replace(".json", "").split("-")
    if len(parts) >= 4:
        return parts[-1]
    return "unknown"


def load_e2e_latency(load_dir: Path) -> dict:
    per_endpoint_records = defaultdict(list)
    per_burst_total_qps = {}

    for p in sorted(load_dir.glob("fortio-burst-*-*.json")):
        payload = load_json(p)
        if not payload:
            continue
        endpoint = parse_endpoint_from_filename(p.name)
        percentiles = parse_fortio_percentiles(payload)
        rec = {
            "file": p.name,
            "actual_qps": float(payload.get("ActualQPS", 0.0)),
            "count": int((payload.get("DurationHistogram") or {}).get("Count", 0)),
            "avg_ms": float(payload.get("DurationHistogram", {}).get("Avg", 0.0)) * 1000.0,
            "p50_ms": percentiles.get(50.0),
            "p90_ms": percentiles.get(90.0),
            "p95_ms": percentiles.get(95.0),
            "p99_ms": percentiles.get(99.0),
            "p999_ms": percentiles.get(99.9),
        }
        per_endpoint_records[endpoint].append(rec)

        # burst id is token at index 2: fortio-burst-<idx>-...
        tokens = p.name.replace(".json", "").split("-")
        if len(tokens) >= 4 and tokens[2].isdigit():
            idx = int(tokens[2])
            per_burst_total_qps[idx] = per_burst_total_qps.get(idx, 0.0) + rec["actual_qps"]

    endpoint_summary = {}
    for endpoint, rows in per_endpoint_records.items():
        p95s = sorted([r["p95_ms"] for r in rows if r["p95_ms"] is not None])
        p99s = sorted([r["p99_ms"] for r in rows if r["p99_ms"] is not None])
        qs = [r["actual_qps"] for r in rows]
        endpoint_summary[endpoint] = {
            "runs": len(rows),
            "avg_actual_qps": safe_mean(qs),
            "max_actual_qps": max(qs) if qs else None,
            "p95_ms_median": percentile(p95s, 50) if p95s else None,
            "p95_ms_max": max(p95s) if p95s else None,
            "p99_ms_median": percentile(p99s, 50) if p99s else None,
            "p99_ms_max": max(p99s) if p99s else None,
        }

    burst_qps = sorted(per_burst_total_qps.values())
    cluster_summary = {
        "burst_count": len(per_burst_total_qps),
        "combined_actual_qps_avg": safe_mean(burst_qps),
        "combined_actual_qps_p95": percentile(sorted(burst_qps), 95) if burst_qps else None,
        "combined_actual_qps_max": max(burst_qps) if burst_qps else None,
    }

    return {
        "endpoint_summary": endpoint_summary,
        "cluster_summary": cluster_summary,
    }


def parse_probe_kv(raw: str) -> dict:
    out = {}
    for token in raw.split():
        if "=" not in token:
            continue
        k, v = token.split("=", 1)
        if k == "code":
            try:
                out[k] = int(v)
            except Exception:
                continue
        else:
            try:
                out[k] = float(v) * 1000.0
            except Exception:
                continue
    return out


def load_service_to_service(network_dir: Path, service_to_nodes: Dict[str, Set[str]]) -> dict:
    p = network_dir / "service-to-service-latency.jsonl"
    if not p.exists():
        return {"path_summary": {}, "global_summary": {}, "node_pair_summary": {}}

    path_stats = defaultdict(lambda: defaultdict(list))
    node_pair_totals: Dict[tuple, List[float]] = defaultdict(list)
    same_node_total = 0
    all_total = 0

    for raw in p.read_text().splitlines():
        raw = raw.strip()
        if not raw:
            continue
        try:
            row = json.loads(raw)
        except Exception:
            continue
        source_pod = row.get("source_pod", "unknown")
        target_service = row.get("target_service", "unknown")
        source_node = row.get("source_node") or "unknown"
        path = f"{source_pod}->{target_service}"
        metrics = parse_probe_kv(row.get("probe", ""))

        if metrics.get("code") is not None:
            path_stats[path]["code"].append(float(metrics["code"]))
        for metric in ("dns", "connect", "ttfb", "total"):
            if metric in metrics:
                path_stats[path][metric].append(metrics[metric])

        if "total" in metrics and source_node != "unknown":
            node_pair_totals[(source_node, target_service)].append(metrics["total"])

        target_nodes = service_to_nodes.get(target_service, set())
        if source_node and target_nodes:
            all_total += 1
            if source_node in target_nodes:
                same_node_total += 1

    summary = {}
    total_samples = 0
    for path, metrics in path_stats.items():
        totals = sorted(metrics.get("total", []))
        if not totals:
            continue
        total_samples += len(totals)
        connect_list = metrics.get("connect", [])
        ttfb_list = metrics.get("ttfb", [])
        queueing_list = [
            t - c for t, c in zip(ttfb_list, connect_list)
            if t is not None and c is not None
        ]
        summary[path] = {
            "samples": len(totals),
            "total_avg_ms": safe_mean(totals),
            "total_p95_ms": percentile(totals, 95),
            "total_p99_ms": percentile(totals, 99),
            "dns_avg_ms": safe_mean(metrics.get("dns", [])),
            "connect_avg_ms": safe_mean(connect_list),
            "ttfb_avg_ms": safe_mean(ttfb_list),
            "queueing_avg_ms": safe_mean(queueing_list) if queueing_list else None,
            "error_rate": (
                len([c for c in metrics.get("code", []) if int(c) >= 400]) / len(metrics.get("code", []))
                if metrics.get("code")
                else None
            ),
        }

    node_pair_summary = {}
    for (src_node, tgt_svc), totals in node_pair_totals.items():
        if not totals:
            continue
        key = f"{src_node} -> {tgt_svc}"
        node_pair_summary[key] = {
            "source_node": src_node,
            "target_service": tgt_svc,
            "samples": len(totals),
            "total_avg_ms": safe_mean(totals),
            "total_p95_ms": percentile(sorted(totals), 95),
            "total_p99_ms": percentile(sorted(totals), 99),
        }

    global_summary = {
        "path_count": len(summary),
        "total_samples": total_samples,
        "intra_node_ratio": (same_node_total / all_total) if all_total > 0 else None,
    }
    return {
        "path_summary": summary,
        "global_summary": global_summary,
        "node_pair_summary": node_pair_summary,
    }


def write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def load_hpa_snapshots(network_dir: Path) -> List[Tuple[str, dict]]:
    """Load HPA snapshots; return list of (timestamp, {hpa_name: {desired, current}})."""
    out = []
    for p in sorted(network_dir.glob("hpa-*.json")):
        payload = load_json(p)
        if not payload:
            continue
        ts = detect_timestamp_from_name(p, "hpa-")
        if ts == "unknown" or not ts.replace("-", "").replace("_", "").isdigit():
            continue
        per_hpa = {}
        for item in payload.get("items", []):
            name = (item.get("metadata") or {}).get("name")
            if not name:
                continue
            status = item.get("status") or {}
            per_hpa[name] = {
                "desired": status.get("desiredReplicas"),
                "current": status.get("currentReplicas"),
            }
        if per_hpa:
            out.append((ts, per_hpa))
    return out


def build_latency_vs_replicas(
    network_dir: Path,
    hpa_snapshots: List[Tuple[str, dict]],
) -> Optional[Path]:
    """Build latency-vs-replicas.csv from HPA snapshots and s2s probes grouped by timestamp."""
    p = network_dir / "service-to-service-latency.jsonl"
    if not p.exists() or not hpa_snapshots:
        return None

    # Group s2s probes by timestamp -> list of total ms
    by_ts: Dict[str, List[float]] = defaultdict(list)
    for raw in p.read_text().splitlines():
        raw = raw.strip()
        if not raw:
            continue
        try:
            row = json.loads(raw)
        except Exception:
            continue
        ts = row.get("timestamp")
        if not ts:
            continue
        metrics = parse_probe_kv(row.get("probe", ""))
        if "total" in metrics:
            by_ts[ts].append(metrics["total"])

    # All HPA names across snapshots
    all_hpa_names = set()
    for _, per_hpa in hpa_snapshots:
        all_hpa_names.update(per_hpa.keys())
    all_hpa_names = sorted(all_hpa_names)

    # Build rows: timestamp, then per-HPA desired/current, then s2s_p95_ms, s2s_p99_ms
    csv_path = network_dir / "latency-vs-replicas.csv"
    rows = []
    for ts, per_hpa in hpa_snapshots:
        totals_at_ts = sorted(by_ts.get(ts, []))
        s2s_p95 = percentile(totals_at_ts, 95) if totals_at_ts else None
        s2s_p99 = percentile(totals_at_ts, 99) if totals_at_ts else None
        row = {"timestamp": ts}
        for name in all_hpa_names:
            info = per_hpa.get(name, {})
            row[f"{name}_desired"] = info.get("desired", "")
            row[f"{name}_current"] = info.get("current", "")
        row["s2s_p95_ms"] = f"{s2s_p95:.2f}" if s2s_p95 is not None else ""
        row["s2s_p99_ms"] = f"{s2s_p99:.2f}" if s2s_p99 is not None else ""
        rows.append(row)

    # Also include timestamps that have s2s but no HPA (e.g. partial overlap)
    hpa_ts_set = {r[0] for r in hpa_snapshots}
    for ts in by_ts:
        if ts in hpa_ts_set:
            continue
        totals_at_ts = sorted(by_ts[ts])
        row = {"timestamp": ts}
        for n in all_hpa_names:
            row[f"{n}_desired"] = ""
            row[f"{n}_current"] = ""
        row["s2s_p95_ms"] = f"{percentile(totals_at_ts, 95):.2f}" if totals_at_ts else ""
        row["s2s_p99_ms"] = f"{percentile(totals_at_ts, 99):.2f}" if totals_at_ts else ""
        rows.append(row)
    rows.sort(key=lambda r: r["timestamp"])

    header = ["timestamp"] + [f"{n}_desired" for n in all_hpa_names] + [f"{n}_current" for n in all_hpa_names] + ["s2s_p95_ms", "s2s_p99_ms"]
    with open(csv_path, "w") as f:
        f.write(",".join(header) + "\n")
        for row in rows:
            f.write(",".join(str(row.get(h, "")) for h in header) + "\n")
    return csv_path


def write_text_report(
    network_dir: Path,
    placement: dict,
    e2e: dict,
    s2s: dict,
) -> None:
    lines = []
    lines.append("Network Analysis Summary")
    lines.append("=" * 80)
    lines.append("")
    lines.append("1) Node -> Pods (latest snapshot)")
    lines.append("-" * 80)
    lines.append(f"Latest timestamp: {placement.get('latest_timestamp', 'n/a')}")
    latest = placement.get("latest_node_to_pods", {})
    if not latest:
        lines.append("No pod snapshots found.")
    else:
        for node, pods in sorted(latest.items()):
            lines.append(f"{node}: {len(pods)} pods")
            for pod in pods:
                lines.append(f"  - {pod}")
    lines.append("")
    lines.append("1b) Service -> Nodes (which service's pods are on which node)")
    lines.append("-" * 80)
    spread = placement.get("service_node_spread", {})
    if spread:
        for svc in sorted(spread.keys()):
            info = spread[svc]
            nodes_used = info.get("nodes_used", [])
            # Prefer pod_count_by_node (latest snapshot); fall back to samples_per_node (legacy)
            counts = info.get("pod_count_by_node") or info.get("samples_per_node", {})
            parts = [f"{n} ({counts.get(n, 0)} pod(s))" for n in nodes_used]
            lines.append(f"  {svc}: {', '.join(parts)}")
    else:
        lines.append("  No service-node spread data.")
    lines.append("")
    lines.append(f"Pods that moved nodes: {len(placement.get('pod_movements', {}))}")
    lines.append("")
    lines.append("2) End-to-end Latency (frontend endpoints)")
    lines.append("-" * 80)
    cluster = e2e.get("cluster_summary", {})
    lines.append(f"Burst count: {cluster.get('burst_count', 0)}")
    lines.append(f"Combined actual QPS avg: {cluster.get('combined_actual_qps_avg')}")
    lines.append(f"Combined actual QPS p95: {cluster.get('combined_actual_qps_p95')}")
    lines.append(f"Combined actual QPS max: {cluster.get('combined_actual_qps_max')}")
    lines.append("")
    for endpoint, data in sorted(e2e.get("endpoint_summary", {}).items()):
        lines.append(f"{endpoint}:")
        lines.append(f"  runs={data.get('runs', 0)} avg_qps={data.get('avg_actual_qps')}")
        lines.append(f"  p95 median={format_ms(data.get('p95_ms_median'))} max={format_ms(data.get('p95_ms_max'))}")
        lines.append(f"  p99 median={format_ms(data.get('p99_ms_median'))} max={format_ms(data.get('p99_ms_max'))}")
    lines.append("")
    lines.append("3) Service-to-Service Latency")
    lines.append("-" * 80)
    g = s2s.get("global_summary", {})
    lines.append(f"Measured paths: {g.get('path_count', 0)}")
    lines.append(f"Latency samples: {g.get('total_samples', 0)}")
    lines.append(f"Intra-node ratio: {g.get('intra_node_ratio')}")
    lines.append("")
    top_paths = sorted(
        s2s.get("path_summary", {}).items(),
        key=lambda item: (item[1].get("total_p95_ms") or -1),
        reverse=True,
    )[:12]
    for path, metric in top_paths:
        lines.append(f"{path}")
        lines.append(
            f"  avg={format_ms(metric.get('total_avg_ms'))} "
            f"p95={format_ms(metric.get('total_p95_ms'))} "
            f"p99={format_ms(metric.get('total_p99_ms'))} "
            f"err={metric.get('error_rate')}"
        )

    lines.append("")
    lines.append("4) Queueing vs network decomposition (connect vs ttfb-connect)")
    lines.append("-" * 80)
    lines.append("  connect ≈ network RTT; queueing_avg = ttfb - connect ≈ server/queue delay")
    path_summary = s2s.get("path_summary", {})
    if path_summary:
        connect_vals = []
        queueing_vals = []
        for path, metric in sorted(path_summary.items(), key=lambda x: (x[1].get("total_p95_ms") or 0), reverse=True)[:15]:
            c = metric.get("connect_avg_ms")
            q = metric.get("queueing_avg_ms")
            if c is not None:
                connect_vals.append(c)
            if q is not None:
                queueing_vals.append(q)
            lines.append(f"  {path}")
            lines.append(f"    connect_avg={format_ms(c)}  queueing_avg(ttfb-connect)={format_ms(q)}  total_avg={format_ms(metric.get('total_avg_ms'))}")
        if connect_vals or queueing_vals:
            lines.append("")
            lines.append(f"  Global (across shown paths): connect_avg={format_ms(safe_mean(connect_vals))}  queueing_avg={format_ms(safe_mean(queueing_vals))}")
    else:
        lines.append("  No path-level probe data.")
    lines.append("")
    lines.append("5) Tail latency by (source_node, target_service)")
    lines.append("-" * 80)
    node_pair = s2s.get("node_pair_summary", {})
    if node_pair:
        top_pairs = sorted(
            node_pair.items(),
            key=lambda x: (x[1].get("total_p95_ms") or -1),
            reverse=True,
        )[:15]
        for key, m in top_pairs:
            lines.append(f"  {key}: samples={m.get('samples', 0)} p95={format_ms(m.get('total_p95_ms'))} p99={format_ms(m.get('total_p99_ms'))}")
    else:
        lines.append("  No node-pair aggregation (need s2s probes with source_node).")

    (network_dir / "analysis-summary.txt").write_text("\n".join(lines) + "\n")


def write_recommendations(network_dir: Path, placement: dict, e2e: dict, s2s: dict) -> None:
    lines = []
    lines.append("# Suggested Extra Metrics for Network-Aware Pod Allocation")
    lines.append("")
    lines.append("1. **Cross-node request ratio per service path**")
    lines.append("   - Why: directly measures how often calls leave the node and pay overlay/network penalty.")
    lines.append("   - How: join source pod node with target endpoint node for each service-to-service sample.")
    lines.append("")
    lines.append("2. **Network-latency amplification under autoscaling**")
    lines.append("   - Why: tracks whether p95/p99 service latency worsens when replica counts increase.")
    lines.append("   - How: correlate `hpa-*.json` desired/current replicas with service path p95.")
    lines.append("")
    lines.append("3. **Tail-latency skew by node pair**")
    lines.append("   - Why: identifies problematic node-to-node paths instead of only service-wide averages.")
    lines.append("   - How: aggregate p95/p99 on `(source_node, target_node)` dimensions.")
    lines.append("")
    lines.append("4. **Queueing vs network decomposition**")
    lines.append("   - Why: helps separate app saturation from pure network effects.")
    lines.append("   - How: compare `connect` and `ttfb` from probes; rising `ttfb-connect` indicates app/queue delay.")
    lines.append("")
    lines.append("5. **Replica locality efficiency score**")
    lines.append("   - Why: single objective metric for scheduler experiments.")
    lines.append("   - How: weighted score using intra-node ratio, p95 total latency, and error rate.")
    lines.append("")
    lines.append("## Current Run Quick Facts")
    lines.append("")
    lines.append(f"- Pod snapshots: {placement.get('snapshot_count', 0)}")
    lines.append(f"- Pod movements detected: {len(placement.get('pod_movements', {}))}")
    lines.append(f"- Endpoint groups analyzed: {len(e2e.get('endpoint_summary', {}))}")
    lines.append(f"- Service path samples: {s2s.get('global_summary', {}).get('total_samples', 0)}")
    lines.append(
        f"- Combined max actual QPS: {e2e.get('cluster_summary', {}).get('combined_actual_qps_max')}"
    )
    lines.append("")
    lines.append("## Implemented in this run")
    lines.append("")
    lines.append("- **Latency vs replica count**: see `latency-vs-replicas.csv` (HPA desired/current vs s2s p95/p99 per timestamp).")
    lines.append("- **Tail latency by (source_node, target_service)**: see `node-pair-latency-summary.json` and section 5 of `analysis-summary.txt`.")
    lines.append("- **Queueing vs network**: see section 4 of `analysis-summary.txt` (connect_avg vs queueing_avg = ttfb - connect per path).")

    (network_dir / "experiment-metrics-recommendations.md").write_text("\n".join(lines) + "\n")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Analyze network + load data.")
    parser.add_argument(
        "data_dir",
        nargs="?",
        help="Path to run dir (defaults to latest under ./data)",
    )
    return parser.parse_args()


def discover_data_dir(cli_path: Optional[str], script_dir: Path) -> Path:
    if cli_path:
        return Path(cli_path).expanduser().resolve()
    data_root = script_dir / "data"
    if not data_root.exists():
        raise FileNotFoundError(f"No data directory found at: {data_root}")
    run_dirs = sorted([p for p in data_root.iterdir() if p.is_dir()], reverse=True)
    if not run_dirs:
        raise FileNotFoundError(f"No run directories found under: {data_root}")
    return run_dirs[0]


def main() -> None:
    args = parse_args()
    script_dir = Path(__file__).parent
    try:
        data_dir = discover_data_dir(args.data_dir, script_dir)
    except FileNotFoundError as exc:
        print(f"Error: {exc}")
        sys.exit(1)

    load_dir = data_dir / "loadgen"
    network_dir = data_dir / "network-analysis"
    if not load_dir.exists() or not network_dir.exists():
        print("Error: expected both loadgen/ and network-analysis/ directories in run data.")
        sys.exit(1)

    pod_snapshots = load_pod_snapshots(network_dir)
    service_to_nodes = load_service_endpoint_nodes(network_dir)
    placement = summarize_pod_placement(pod_snapshots)
    e2e = load_e2e_latency(load_dir)
    s2s = load_service_to_service(network_dir, service_to_nodes)

    write_json(network_dir / "pod-placement-analysis.json", placement)
    write_json(network_dir / "e2e-latency-summary.json", e2e)
    write_json(network_dir / "service-to-service-latency-summary.json", {
        "path_summary": s2s["path_summary"],
        "global_summary": s2s["global_summary"],
    })
    write_json(network_dir / "node-pair-latency-summary.json", {
        "by_source_node_target_service": s2s.get("node_pair_summary", {}),
    })
    write_text_report(network_dir, placement, e2e, s2s)
    write_recommendations(network_dir, placement, e2e, s2s)

    hpa_snapshots = load_hpa_snapshots(network_dir)
    latency_vs_replicas_path = build_latency_vs_replicas(network_dir, hpa_snapshots)

    print("=" * 72)
    print("Analysis complete")
    print("=" * 72)
    print(f"Data directory: {data_dir}")
    print(f"Generated: {network_dir / 'analysis-summary.txt'}")
    print(f"Generated: {network_dir / 'pod-placement-analysis.json'}")
    print(f"Generated: {network_dir / 'e2e-latency-summary.json'}")
    print(f"Generated: {network_dir / 'service-to-service-latency-summary.json'}")
    print(f"Generated: {network_dir / 'node-pair-latency-summary.json'}")
    if latency_vs_replicas_path:
        print(f"Generated: {latency_vs_replicas_path}")
    print(f"Generated: {network_dir / 'experiment-metrics-recommendations.md'}")


if __name__ == "__main__":
    main()
