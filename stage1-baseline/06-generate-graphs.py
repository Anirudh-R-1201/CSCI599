#!/usr/bin/env python3
"""
Generate visualization graphs from baseline test data.
Produces graphs for latency, QPS, and pod placement analysis.
"""

import argparse
import glob
import json
import os
import sys
from collections import defaultdict
from pathlib import Path

try:
    import matplotlib
    matplotlib.use('Agg')  # Non-interactive backend
    import matplotlib.pyplot as plt
    import numpy as np
except ImportError:
    print("Error: matplotlib is required. Install with: pip3 install matplotlib")
    sys.exit(1)


def load_burst_data(data_dir):
    """Load latency data from all fortio burst files.
    Supports both fortio-burst-N.json and fortio-burst-N-{home,product,cart}.json.
    """
    loadgen_dir = os.path.join(data_dir, "loadgen")
    burst_files = sorted(glob.glob(os.path.join(loadgen_dir, "fortio-burst-*.json")))

    bursts = []
    for file_path in burst_files:
        with open(file_path, 'r') as f:
            data = json.load(f)

        # Parse index: fortio-burst-0.json -> 0; fortio-burst-0-home.json -> 0
        base = os.path.basename(file_path).replace(".json", "").replace("fortio-burst-", "")
        parts = base.split("-")
        try:
            burst_index = int(parts[0])
        except (ValueError, IndexError):
            burst_index = len(bursts)

        percentiles = {p["Percentile"]: p["Value"] for p in data.get("DurationHistogram", {}).get("Percentiles", [])}

        burst_info = {
            "file": os.path.basename(file_path),
            "index": burst_index,
            "requested_qps": float(data.get("RequestedQPS", 0)),
            "actual_qps": data.get("ActualQPS", 0),
            "duration_ns": data.get("ActualDuration", 0),
            "duration_s": data.get("ActualDuration", 0) / 1e9,
            "p50": percentiles.get(50, 0),
            "p75": percentiles.get(75, 0),
            "p90": percentiles.get(90, 0),
            "p95": percentiles.get(95, 0),
            "p99": percentiles.get(99, 0),
            "p999": percentiles.get(99.9, 0),
            "avg": data.get("DurationHistogram", {}).get("Avg", 0),
            "count": data.get("DurationHistogram", {}).get("Count", 0),
        }
        bursts.append(burst_info)

    return sorted(bursts, key=lambda x: (x["index"], x["file"]))


def load_pod_placement_data(data_dir):
    """Load pod placement snapshots over time.
    Prefers pod-placement/ (index.jsonl + pods-*.json); falls back to network-analysis/pod-network-*.json.
    """
    placement_dir = os.path.join(data_dir, "pod-placement")
    network_dir = os.path.join(data_dir, "network-analysis")

    # Try legacy pod-placement/ first
    if os.path.exists(placement_dir):
        index_file = os.path.join(placement_dir, "index.jsonl")
        if os.path.exists(index_file):
            snapshots = []
            with open(index_file, 'r') as f:
                for line in f:
                    entry = json.loads(line.strip())
                    snapshot_file = os.path.join(placement_dir, entry["file"])
                    if not os.path.exists(snapshot_file):
                        continue
                    with open(snapshot_file, 'r') as sf:
                        snapshot_data = json.load(sf)
                    node_counts = defaultdict(int)
                    for pod in snapshot_data.get("items", []):
                        if pod.get("metadata", {}).get("namespace") == "default":
                            node = pod.get("spec", {}).get("nodeName", "unknown")
                            if node and node != "unknown":
                                node_counts[node] += 1
                    snapshots.append({
                        "timestamp": entry["timestamp"],
                        "file": entry["file"],
                        "index": int(entry["file"].replace("pods-", "").replace(".json", "")),
                        "node_counts": dict(node_counts),
                    })
            if snapshots:
                return sorted(snapshots, key=lambda x: x["index"])

    # Fallback: network-analysis/pod-network-*.json (from 03e)
    if os.path.exists(network_dir):
        pod_files = sorted(glob.glob(os.path.join(network_dir, "pod-network-*.json")))
        snapshots = []
        for i, file_path in enumerate(pod_files):
            with open(file_path, 'r') as f:
                snapshot_data = json.load(f)
            stem = os.path.basename(file_path).replace("pod-network-", "").replace(".json", "")
            node_counts = defaultdict(int)
            for pod in snapshot_data.get("items", []):
                if pod.get("metadata", {}).get("namespace") == "default":
                    node = pod.get("spec", {}).get("nodeName", "unknown")
                    if node and node != "unknown":
                        node_counts[node] += 1
            snapshots.append({
                "timestamp": stem,
                "file": os.path.basename(file_path),
                "index": i,
                "node_counts": dict(node_counts),
            })
        if snapshots:
            return snapshots

    return None


def load_service_placement(data_dir):
    """Load service -> nodes placement from network-analysis/pod-placement-analysis.json."""
    path = os.path.join(data_dir, "network-analysis", "pod-placement-analysis.json")
    if not os.path.exists(path):
        return None
    try:
        with open(path, "r") as f:
            return json.load(f)
    except Exception:
        return None


def plot_service_placement(placement, output_dir):
    """Plot which service's pods are on which node (heatmap: service x node, value = pod count, average over snapshots)."""
    # Prefer average over all snapshots; fall back to latest snapshot
    spread = placement.get("service_node_spread_avg") or placement.get("service_node_spread") if placement else None
    if not spread:
        print("⚠ No service_node_spread in placement, skipping service placement graph")
        return

    use_avg = bool(placement.get("service_node_spread_avg"))
    services = sorted(spread.keys())
    all_nodes = set()
    for info in spread.values():
        all_nodes.update(info.get("nodes_used", []))
    nodes = sorted(all_nodes)

    # Short labels for axes (strip long hostnames to last part)
    def short_node(n):
        return n.split(".")[0] if n else n

    node_labels = [short_node(n) for n in nodes]
    # Build matrix: rows = services, cols = nodes
    data = []
    for svc in services:
        counts = spread[svc].get("pod_count_by_node") or spread[svc].get("samples_per_node", {})
        row = [counts.get(n, 0) for n in nodes]
        data.append(row)

    if not data or not nodes:
        print("⚠ No service/node data for placement heatmap")
        return

    fig, ax = plt.subplots(figsize=(max(8, len(nodes) * 1.5), max(6, len(services) * 0.4)))
    vmax = max(max(r) for r in data) or 1
    im = ax.imshow(data, cmap="Blues", aspect="auto", vmin=0, vmax=vmax)

    ax.set_xticks(range(len(nodes)))
    ax.set_xticklabels(node_labels, rotation=45, ha="right")
    ax.set_yticks(range(len(services)))
    ax.set_yticklabels(services)

    ax.set_xlabel("Node", fontsize=12)
    ax.set_ylabel("Service", fontsize=12)
    ax.set_title("5. Placement: which service's pods are on which node (average over all snapshots)", fontsize=12, fontweight="bold")

    for i in range(len(services)):
        for j in range(len(nodes)):
            v = data[i][j]
            if v > 0:
                label = f"{v:.1f}" if use_avg and isinstance(v, float) and v != int(v) else str(int(round(v)))
                ax.text(j, i, label, ha="center", va="center",
                        color="white" if v >= vmax / 2 else "black", fontsize=10)

    plt.colorbar(im, ax=ax, label="Pod count (average over all snapshots)")
    plt.tight_layout()
    output_path = os.path.join(output_dir, "05_service_placement_by_node.png")
    plt.savefig(output_path, dpi=300, bbox_inches="tight")
    print(f"✓ Generated: {output_path}")
    plt.close()


def plot_latency_percentiles(bursts, output_dir):
    """Plot mean latency percentiles per burst with normalised QPS in background."""
    from collections import defaultdict

    # Average across endpoints (home/product/cart) sharing the same burst index.
    by_index = defaultdict(lambda: {"p50": [], "p95": [], "p99": [], "p999": [], "qps": []})
    for b in bursts:
        i = b["index"]
        by_index[i]["p50"].append(b["p50"] * 1000)
        by_index[i]["p95"].append(b["p95"] * 1000)
        by_index[i]["p99"].append(b["p99"] * 1000)
        by_index[i]["p999"].append(b["p999"] * 1000)
        by_index[i]["qps"].append(b["actual_qps"])

    sorted_indices = sorted(by_index.keys())
    mean_p50  = [np.mean(by_index[i]["p50"])  for i in sorted_indices]
    mean_p95  = [np.mean(by_index[i]["p95"])  for i in sorted_indices]
    mean_p99  = [np.mean(by_index[i]["p99"])  for i in sorted_indices]
    mean_p999 = [np.mean(by_index[i]["p999"]) for i in sorted_indices]
    mean_qps  = [np.mean(by_index[i]["qps"])  for i in sorted_indices]

    # Normalise QPS to [0, 1] so it fits as a background fill.
    max_qps = max(mean_qps) if max(mean_qps) > 0 else 1.0
    norm_qps = [q / max_qps for q in mean_qps]

    fig, ax = plt.subplots(figsize=(14, 6))

    # Background: normalised QPS bars on a twin y-axis.
    ax_bg = ax.twinx()
    ax_bg.bar(sorted_indices, norm_qps, color="grey", alpha=0.18, width=0.8, zorder=1)
    ax_bg.set_ylim(0, 3.5)   # Push bars to bottom third so they don't obscure lines.
    ax_bg.set_yticks([0, 0.5, 1.0])
    ax_bg.set_yticklabels(["0", "0.5×", "peak"], fontsize=9, color="grey")
    ax_bg.set_ylabel("Normalised QPS (relative to peak)", fontsize=9, color="grey")
    ax_bg.tick_params(axis="y", colors="grey")

    # Foreground: mean latency lines.
    ax.plot(sorted_indices, mean_p50,  'o-', label='p50',   linewidth=2, markersize=5, zorder=3)
    ax.plot(sorted_indices, mean_p95,  's-', label='p95',   linewidth=2, markersize=5, zorder=3)
    ax.plot(sorted_indices, mean_p99,  '^-', label='p99',   linewidth=2, markersize=5, zorder=3)
    ax.plot(sorted_indices, mean_p999, 'v-', label='p99.9', linewidth=2, markersize=5, zorder=3)

    ax.set_xlabel('Burst index', fontsize=12)
    ax.set_ylabel('Latency (ms)', fontsize=12)
    ax.set_title('2. Response: mean latency percentiles over traffic bursts', fontsize=14, fontweight='bold')
    ax.legend(loc='upper right', fontsize=10)
    ax.grid(True, alpha=0.3, zorder=2)
    ax.set_zorder(ax_bg.get_zorder() + 1)
    ax.patch.set_visible(False)  # Let the twin axis background show through.

    plt.tight_layout()
    output_path = os.path.join(output_dir, "02_latency_percentiles.png")
    plt.savefig(output_path, dpi=300, bbox_inches='tight')
    print(f"✓ Generated: {output_path}")
    plt.close()


def plot_qps_comparison(bursts, output_dir):
    """Plot actual QPS per burst."""
    fig, ax = plt.subplots(figsize=(14, 6))

    indices = [b["index"] for b in bursts]
    actual = [b["actual_qps"] for b in bursts]

    x = np.arange(len(indices))

    ax.bar(x, actual, alpha=0.8, label='Actual QPS')

    ax.set_xlabel('Burst index', fontsize=12)
    ax.set_ylabel('Queries per second (QPS)', fontsize=12)
    ax.set_title('1. Load: actual QPS per burst', fontsize=14, fontweight='bold')
    ax.set_xticks(x[::2])  # Show every 2nd label to avoid crowding
    ax.set_xticklabels([str(i) for i in indices[::2]])
    ax.grid(True, alpha=0.3, axis='y')

    plt.tight_layout()
    output_path = os.path.join(output_dir, "01_qps_comparison.png")
    plt.savefig(output_path, dpi=300, bbox_inches='tight')
    print(f"✓ Generated: {output_path}")
    plt.close()


def plot_latency_vs_qps(bursts, output_dir):
    """Scatter plot of latency vs QPS to show correlation."""
    fig, ax = plt.subplots(figsize=(10, 6))
    
    qps = [b["actual_qps"] for b in bursts]
    p50 = [b["p50"] * 1000 for b in bursts]
    p95 = [b["p95"] * 1000 for b in bursts]
    p99 = [b["p99"] * 1000 for b in bursts]
    
    ax.scatter(qps, p50, alpha=0.6, s=60, label='p50', marker='o')
    ax.scatter(qps, p95, alpha=0.6, s=60, label='p95', marker='s')
    ax.scatter(qps, p99, alpha=0.6, s=60, label='p99', marker='^')
    
    ax.set_xlabel('Actual QPS', fontsize=12)
    ax.set_ylabel('Latency (ms)', fontsize=12)
    ax.set_title('3. Latency vs load: does higher QPS increase latency?', fontsize=14, fontweight='bold')
    ax.legend(loc='best', fontsize=10)
    ax.grid(True, alpha=0.3)
    
    plt.tight_layout()
    output_path = os.path.join(output_dir, "03_latency_vs_qps.png")
    plt.savefig(output_path, dpi=300, bbox_inches='tight')
    print(f"✓ Generated: {output_path}")
    plt.close()


def plot_pod_distribution(snapshots, output_dir):
    """Plot pod distribution across nodes over time."""
    if not snapshots:
        print("⚠ No pod placement data found, skipping pod distribution graph")
        return
    
    fig, ax = plt.subplots(figsize=(14, 6))
    
    # Get all unique nodes
    all_nodes = set()
    for snap in snapshots:
        all_nodes.update(snap["node_counts"].keys())
    all_nodes = sorted(all_nodes)
    
    # Prepare data for stacked area plot
    indices = [s["index"] for s in snapshots]
    node_data = {node: [] for node in all_nodes}
    
    for snap in snapshots:
        for node in all_nodes:
            node_data[node].append(snap["node_counts"].get(node, 0))
    
    # Create stacked area plot
    colors = plt.cm.Set3(np.linspace(0, 1, len(all_nodes)))
    ax.stackplot(indices, *[node_data[node] for node in all_nodes], 
                 labels=all_nodes, alpha=0.8, colors=colors)
    
    ax.set_xlabel('Snapshot index', fontsize=12)
    ax.set_ylabel('Number of pods', fontsize=12)
    ax.set_title('4. Scaling: pod count per node over time', fontsize=14, fontweight='bold')
    ax.legend(loc='upper left', fontsize=10, bbox_to_anchor=(1, 1))
    ax.grid(True, alpha=0.3, axis='y')
    
    plt.tight_layout()
    output_path = os.path.join(output_dir, "04_pod_distribution.png")
    plt.savefig(output_path, dpi=300, bbox_inches='tight')
    print(f"✓ Generated: {output_path}")
    plt.close()


def plot_latency_distribution(bursts, output_dir):
    """Box plot of latency distribution across all bursts."""
    fig, ax = plt.subplots(figsize=(10, 6))
    
    # Prepare data for box plot
    p50_data = [b["p50"] * 1000 for b in bursts]
    p95_data = [b["p95"] * 1000 for b in bursts]
    p99_data = [b["p99"] * 1000 for b in bursts]
    p999_data = [b["p999"] * 1000 for b in bursts]
    
    data = [p50_data, p95_data, p99_data, p999_data]
    labels = ['p50', 'p95', 'p99', 'p99.9']
    
    bp = ax.boxplot(data, tick_labels=labels, patch_artist=True, showmeans=True)
    
    # Customize colors
    colors = ['lightblue', 'lightgreen', 'lightyellow', 'lightcoral']
    for patch, color in zip(bp['boxes'], colors):
        patch.set_facecolor(color)
    
    ax.set_ylabel('Latency (ms)', fontsize=12)
    ax.set_title('6. Summary: latency distribution across all bursts', fontsize=14, fontweight='bold')
    ax.grid(True, alpha=0.3, axis='y')
    
    plt.tight_layout()
    output_path = os.path.join(output_dir, "06_latency_distribution.png")
    plt.savefig(output_path, dpi=300, bbox_inches='tight')
    print(f"✓ Generated: {output_path}")
    plt.close()


def generate_summary_stats(bursts, snapshots, output_dir):
    """Generate summary statistics text file."""
    output_path = os.path.join(output_dir, "summary_stats.txt")
    
    with open(output_path, 'w') as f:
        f.write("Baseline Test Summary Statistics\n")
        f.write("=" * 60 + "\n\n")
        
        # Latency stats
        f.write("LATENCY METRICS:\n")
        f.write("-" * 40 + "\n")
        p50_vals = [b["p50"] * 1000 for b in bursts]
        p95_vals = [b["p95"] * 1000 for b in bursts]
        p99_vals = [b["p99"] * 1000 for b in bursts]
        p999_vals = [b["p999"] * 1000 for b in bursts]
        
        f.write(f"p50:  mean={np.mean(p50_vals):.2f}ms, median={np.median(p50_vals):.2f}ms, "
                f"min={np.min(p50_vals):.2f}ms, max={np.max(p50_vals):.2f}ms\n")
        f.write(f"p95:  mean={np.mean(p95_vals):.2f}ms, median={np.median(p95_vals):.2f}ms, "
                f"min={np.min(p95_vals):.2f}ms, max={np.max(p95_vals):.2f}ms\n")
        f.write(f"p99:  mean={np.mean(p99_vals):.2f}ms, median={np.median(p99_vals):.2f}ms, "
                f"min={np.min(p99_vals):.2f}ms, max={np.max(p99_vals):.2f}ms\n")
        f.write(f"p999: mean={np.mean(p999_vals):.2f}ms, median={np.median(p999_vals):.2f}ms, "
                f"min={np.min(p999_vals):.2f}ms, max={np.max(p999_vals):.2f}ms\n\n")
        
        # QPS stats
        f.write("QPS METRICS:\n")
        f.write("-" * 40 + "\n")
        qps_vals = [b["actual_qps"] for b in bursts]
        f.write(f"Actual QPS: mean={np.mean(qps_vals):.2f}, median={np.median(qps_vals):.2f}, "
                f"min={np.min(qps_vals):.2f}, max={np.max(qps_vals):.2f}\n")
        f.write(f"Total bursts: {len(bursts)}\n")
        f.write(f"Total requests: {sum(b['count'] for b in bursts)}\n\n")
        
        # Pod placement stats
        if snapshots:
            f.write("POD PLACEMENT METRICS:\n")
            f.write("-" * 40 + "\n")
            f.write(f"Total snapshots: {len(snapshots)}\n")
            all_nodes = set()
            for snap in snapshots:
                all_nodes.update(snap["node_counts"].keys())
            f.write(f"Nodes: {', '.join(sorted(all_nodes))}\n")
            
            # Average pods per node
            for node in sorted(all_nodes):
                counts = [snap["node_counts"].get(node, 0) for snap in snapshots]
                f.write(f"  {node}: mean={np.mean(counts):.1f} pods, "
                        f"min={np.min(counts)}, max={np.max(counts)}\n")
    
    print(f"✓ Generated: {output_path}")


# ---------------------------------------------------------------------------
# Data loaders for network-analysis s2s probes
# ---------------------------------------------------------------------------

def load_s2s_data(data_dir):
    """Load service-to-service probe records from network-analysis/service-to-service-latency.jsonl."""
    path = os.path.join(data_dir, "network-analysis", "service-to-service-latency.jsonl")
    if not os.path.exists(path):
        return []
    records = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except Exception:
                continue
            metrics = {}
            for token in row.get("probe", "").split():
                if "=" in token:
                    k, v = token.split("=", 1)
                    try:
                        # Probe string is written in ms (03e: curl s→ms; fortio: already ms)
                        metrics[k] = float(v)
                    except ValueError:
                        try:
                            metrics[k] = int(v)
                        except ValueError:
                            pass
            records.append({
                "timestamp": row.get("timestamp", ""),
                "source_pod": row.get("source_pod", "unknown"),
                "source_node": row.get("source_node", "unknown"),
                "target_service": row.get("target_service", "unknown"),
                **metrics,
            })
    return records


def load_service_endpoint_nodes(data_dir):
    """Return {service_name: set(node_names)} aggregated from service-endpoints-*.json."""
    network_dir = os.path.join(data_dir, "network-analysis")
    service_to_nodes = defaultdict(set)
    for path in sorted(glob.glob(os.path.join(network_dir, "service-endpoints-*.json"))):
        try:
            with open(path) as f:
                payload = json.load(f)
        except Exception:
            continue
        for item in payload.get("items", []):
            svc = (item.get("metadata") or {}).get("name", "unknown")
            for subset in item.get("subsets", []) or []:
                for addr in subset.get("addresses", []) or []:
                    node = addr.get("nodeName")
                    if node:
                        service_to_nodes[svc].add(node)
    return {k: v for k, v in service_to_nodes.items()}


def load_latency_vs_replicas(data_dir):
    """Load network-analysis/latency-vs-replicas.csv; return list of row dicts."""
    path = os.path.join(data_dir, "network-analysis", "latency-vs-replicas.csv")
    if not os.path.exists(path):
        return []
    rows = []
    with open(path) as f:
        header = None
        for line in f:
            line = line.strip()
            if not line:
                continue
            if header is None:
                header = line.split(",")
                continue
            rows.append(dict(zip(header, line.split(","))))
    return rows


# ---------------------------------------------------------------------------
# Graph 07 – cross-node call ratio per service pair
# ---------------------------------------------------------------------------

# Canonical list so we always show all boutique services (reduces sparse chart)
BOUTIQUE_SERVICES = [
    "frontend", "productcatalogservice", "recommendationservice", "cartservice",
    "checkoutservice", "paymentservice", "shippingservice", "currencyservice",
]

def plot_cross_node_ratio(s2s_records, service_to_nodes, output_dir, from_loadgen_only=False):
    """Bar chart: % of cross-node calls per (source_app → target_service) pair."""
    if not s2s_records:
        print("⚠ No s2s data, skipping cross-node ratio graph")
        return

    def pod_to_app(pod_name):
        parts = pod_name.rsplit("-", 2)
        base = parts[0] if len(parts) >= 2 else pod_name
        if (base or "").lower() == "s2s" or (pod_name or "").startswith("s2s-prober"):
            return "prober"
        return base

    pair_counts = defaultdict(lambda: {"total": 0, "cross": 0})
    for rec in s2s_records:
        source_node = rec.get("source_node", "unknown")
        target_service = rec.get("target_service", "unknown")
        source_app = pod_to_app(rec.get("source_pod", "unknown"))
        pair = f"{source_app}→{target_service}"
        target_nodes = service_to_nodes.get(target_service, set())
        pair_counts[pair]["total"] += 1
        if source_node not in target_nodes:
            pair_counts[pair]["cross"] += 1

    if not pair_counts:
        print("⚠ No pair data for cross-node ratio graph")
        return

    # Show all boutique services for the source(s) we have so the chart isn’t sparse
    source_apps = sorted({p.split("→", 1)[0] for p in pair_counts})
    pairs = []
    for src in source_apps:
        for svc in BOUTIQUE_SERVICES:
            pairs.append(f"{src}→{svc}")
    # If no standard pairs in data, fall back to whatever we have, sorted by ratio
    if not any(p in pair_counts for p in pairs):
        pairs = sorted(pair_counts, key=lambda p: pair_counts[p]["cross"] / max(pair_counts[p]["total"], 1), reverse=True)
    else:
        # Sort by cross-node ratio descending (high first), then by service name
        def key(p):
            c = pair_counts.get(p, {"total": 0, "cross": 0})
            r = c["cross"] / max(c["total"], 1)
            return (-r, p)
        pairs = sorted(pairs, key=key)

    def _ratio(p):
        c = pair_counts.get(p, {"total": 0, "cross": 0})
        return c["cross"] / max(c["total"], 1) * 100
    ratios = [_ratio(p) for p in pairs]
    colors = ["#d73027" if r > 50 else "#fc8d59" if r > 25 else "#91bfdb" for r in ratios]

    title = "7. Network: cross-node call ratio per service pair"
    if from_loadgen_only:
        title += " (from load generator; deploy s2s-prober for client→service)"
    else:
        title += " (client prober → boutique service)"

    fig, ax = plt.subplots(figsize=(max(10, len(pairs) * 0.55), 6))
    ax.bar(range(len(pairs)), ratios, color=colors, alpha=0.88)
    ax.axhline(50, color="red", linestyle="--", linewidth=1, alpha=0.5, label="50% threshold")
    ax.set_xticks(range(len(pairs)))
    ax.set_xticklabels(pairs, rotation=45, ha="right", fontsize=8)
    ax.set_ylabel("Cross-node calls (%)", fontsize=12)
    ax.set_ylim(0, 108)
    ax.set_title(title, fontsize=14, fontweight="bold")
    ax.legend(fontsize=10)
    ax.grid(True, alpha=0.3, axis="y")
    plt.tight_layout()
    output_path = os.path.join(output_dir, "07_cross_node_ratio.png")
    plt.savefig(output_path, dpi=300, bbox_inches="tight")
    print(f"✓ Generated: {output_path}")
    plt.close()


# ---------------------------------------------------------------------------
# Graph 08 – same-node vs cross-node latency CDF
# ---------------------------------------------------------------------------

def plot_same_vs_cross_node_cdf(s2s_records, service_to_nodes, output_dir, from_loadgen_only=False):
    """CDF of total latency split into same-node vs cross-node calls."""
    if not s2s_records:
        print("⚠ No s2s data, skipping CDF graph")
        return

    same_node, cross_node = [], []
    for rec in s2s_records:
        total = rec.get("total")
        if total is None:
            continue
        source_node = rec.get("source_node", "unknown")
        target_nodes = service_to_nodes.get(rec.get("target_service", ""), set())
        if source_node == "unknown" or not target_nodes:
            continue
        if source_node in target_nodes:
            same_node.append(total)
        else:
            cross_node.append(total)

    if not same_node and not cross_node:
        print("⚠ No latency data for CDF graph")
        return

    title = "8. Network penalty: same-node vs cross-node latency CDF"
    if from_loadgen_only:
        title += " (from load generator)"
    else:
        title += " (client prober → service)"

    fig, ax = plt.subplots(figsize=(10, 6))
    for latencies, label, color in [
        (same_node,  f"Same-node  (n={len(same_node)})",  "#2166ac"),
        (cross_node, f"Cross-node (n={len(cross_node)})", "#d6604d"),
    ]:
        if latencies:
            sv = np.sort(latencies)
            ax.plot(sv, np.arange(1, len(sv) + 1) / len(sv), linewidth=2.5, label=label, color=color)

    ax.set_xlabel("Total latency (ms)", fontsize=12)
    ax.set_ylabel("CDF", fontsize=12)
    ax.set_ylim(0, 1.05)
    ax.set_title(title + "\n(Same-node = client & service on same host; cross-node = different hosts. CDF = fraction of requests with latency ≤ x.)", fontsize=12, fontweight="bold")
    ax.legend(fontsize=11)
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    output_path = os.path.join(output_dir, "08_same_vs_cross_node_cdf.png")
    plt.savefig(output_path, dpi=300, bbox_inches="tight")
    print(f"✓ Generated: {output_path}")
    plt.close()


# ---------------------------------------------------------------------------
# Graph 09 – p95 latency vs total replica count (scatter)
# ---------------------------------------------------------------------------

def plot_p95_vs_replicas(latency_replicas_rows, output_dir):
    """Scatter: s2s p95 latency vs total running replicas, coloured by time order."""
    if not latency_replicas_rows:
        print("⚠ No latency-vs-replicas data, skipping p95 vs replicas scatter")
        return

    total_replicas, p95_vals = [], []
    for row in latency_replicas_rows:
        p95_str = row.get("s2s_p95_ms", "")
        if not p95_str:
            continue
        try:
            p95 = float(p95_str)
        except ValueError:
            continue
        current_total = sum(
            int(v) for k, v in row.items()
            if k.endswith("_current") and v and v.isdigit()
        )
        if current_total > 0:
            total_replicas.append(current_total)
            p95_vals.append(p95)

    if not total_replicas:
        print("⚠ No data points for p95 vs replicas scatter")
        return

    replica_min, replica_max = min(total_replicas), max(total_replicas)
    subtitle = f"Replicas in this run: {replica_min}–{replica_max}" if replica_min != replica_max else f"Replicas in this run: {replica_min}"

    fig, ax = plt.subplots(figsize=(10, 6))
    sc = ax.scatter(total_replicas, p95_vals, c=range(len(total_replicas)),
                    cmap="plasma", alpha=0.75, s=60, edgecolors="none")
    plt.colorbar(sc, ax=ax, label="Time (snapshot order → later = brighter)")
    ax.set_xlabel("Total current replicas (all services)", fontsize=12)
    ax.set_ylabel("s2s p95 latency (ms)", fontsize=12)
    ax.set_title("9. Scaling cost: p95 latency vs total running replicas\n" + subtitle, fontsize=14, fontweight="bold")
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    output_path = os.path.join(output_dir, "09_p95_vs_replicas.png")
    plt.savefig(output_path, dpi=300, bbox_inches="tight")
    print(f"✓ Generated: {output_path}")
    plt.close()


# ---------------------------------------------------------------------------
# Graph 09b – p95 latency vs node count (cross-node spread → higher latency)
# ---------------------------------------------------------------------------

def plot_p95_vs_node_count(latency_replicas_rows, output_dir):
    """Scatter: s2s p95 latency vs number of nodes with pods (shows cross-node latency cost)."""
    node_counts, p95_vals = [], []
    for row in latency_replicas_rows:
        nc_str = row.get("node_count", "").strip()
        p95_str = row.get("s2s_p95_ms", "").strip()
        if not nc_str or not p95_str:
            continue
        try:
            nc = int(nc_str)
            p95 = float(p95_str)
        except ValueError:
            continue
        if nc > 0:
            node_counts.append(nc)
            p95_vals.append(p95)

    if not node_counts:
        print("⚠ No node_count data in latency-vs-replicas, skipping p95 vs node count graph")
        return

    nc_min, nc_max = min(node_counts), max(node_counts)
    if nc_min == nc_max:
        print("⚠ Skipping graph 9b: node count is constant ({}) in this run — no spread variation to plot.".format(nc_min))
        return

    subtitle = f"Node count in this run: {nc_min}–{nc_max}. Higher spread often increases cross-node latency."

    fig, ax = plt.subplots(figsize=(10, 6))
    sc = ax.scatter(node_counts, p95_vals, c=range(len(node_counts)),
                    cmap="viridis", alpha=0.75, s=60, edgecolors="none")
    plt.colorbar(sc, ax=ax, label="Time (snapshot order → later = brighter)")
    ax.set_xlabel("Number of nodes with workload pods", fontsize=12)
    ax.set_ylabel("s2s p95 latency (ms)", fontsize=12)
    ax.set_title("9b. Cross-node cost: p95 latency vs pod spread across nodes\n" + subtitle, fontsize=14, fontweight="bold")
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    output_path = os.path.join(output_dir, "09b_p95_vs_node_count.png")
    plt.savefig(output_path, dpi=300, bbox_inches="tight")
    print(f"✓ Generated: {output_path}")
    plt.close()


# ---------------------------------------------------------------------------
# Graph 10 – node-pair p95 latency heatmap
# ---------------------------------------------------------------------------

def plot_node_pair_heatmap(s2s_records, output_dir, from_loadgen_only=False):
    """Heatmap: p95 latency by (source_node × target_service)."""
    if not s2s_records:
        print("⚠ No s2s data, skipping node-pair heatmap")
        return

    def short_node(n):
        return n.split(".")[0]

    pair_latencies = defaultdict(list)
    for rec in s2s_records:
        total = rec.get("total")
        sn = rec.get("source_node", "unknown")
        ts = rec.get("target_service", "unknown")
        if total is not None and sn != "unknown":
            pair_latencies[(sn, ts)].append(total)

    if not pair_latencies:
        print("⚠ No data for node-pair heatmap")
        return

    source_nodes = sorted({k[0] for k in pair_latencies})
    target_services = sorted({k[1] for k in pair_latencies})

    matrix = np.full((len(source_nodes), len(target_services)), np.nan)
    for i, sn in enumerate(source_nodes):
        for j, ts in enumerate(target_services):
            vals = sorted(pair_latencies.get((sn, ts), []))
            if vals:
                matrix[i][j] = vals[min(int(len(vals) * 0.95), len(vals) - 1)]

    title = "10. Topology: p95 latency by source node → target service"
    if from_loadgen_only:
        title += " (from load generator)"
    else:
        title += " (client prober → service)"

    fig, ax = plt.subplots(figsize=(max(10, len(target_services) * 0.9), max(4, len(source_nodes) * 0.9)))
    masked = np.ma.masked_invalid(matrix)
    im = ax.imshow(masked, cmap="YlOrRd", aspect="auto")
    plt.colorbar(im, ax=ax, label="p95 latency (ms)")

    ax.set_xticks(range(len(target_services)))
    ax.set_xticklabels(target_services, rotation=45, ha="right", fontsize=9)
    ax.set_yticks(range(len(source_nodes)))
    ax.set_yticklabels([short_node(n) for n in source_nodes], fontsize=9)
    ax.set_xlabel("Target service", fontsize=12)
    ax.set_ylabel("Source node", fontsize=12)
    ax.set_title(title, fontsize=14, fontweight="bold")

    vmax = np.nanmax(matrix) if not np.all(np.isnan(matrix)) else 1
    for i in range(len(source_nodes)):
        for j in range(len(target_services)):
            v = matrix[i][j]
            if not np.isnan(v):
                ax.text(j, i, f"{v:.0f}", ha="center", va="center", fontsize=7,
                        color="white" if v > vmax * 0.6 else "black")

    plt.tight_layout()
    output_path = os.path.join(output_dir, "10_node_pair_latency_heatmap.png")
    plt.savefig(output_path, dpi=300, bbox_inches="tight")
    print(f"✓ Generated: {output_path}")
    plt.close()


# ---------------------------------------------------------------------------
# Graph 10b – latency to each service by source node (e.g. frontend: from node1, node2, …)
# ---------------------------------------------------------------------------

def plot_latency_to_service_by_node(s2s_records, output_dir, from_loadgen_only=False):
    """Per target service: bar chart of p95 latency from each source node (answers: latency to frontend from each node?)."""
    if not s2s_records:
        print("⚠ No s2s data, skipping latency-by-node graph")
        return

    def short_node(n):
        return n.split(".")[0]

    pair_latencies = defaultdict(list)
    for rec in s2s_records:
        total = rec.get("total")
        sn = rec.get("source_node", "unknown")
        ts = rec.get("target_service", "unknown")
        if total is not None and sn != "unknown" and ts:
            pair_latencies[(sn, ts)].append(total)

    if not pair_latencies:
        print("⚠ No data for latency-by-node graph")
        return

    source_nodes = sorted({k[0] for k in pair_latencies})
    target_services = [s for s in BOUTIQUE_SERVICES if s in {k[1] for k in pair_latencies}]
    if not target_services:
        target_services = sorted({k[1] for k in pair_latencies})

    n_services = len(target_services)
    n_cols = min(4, n_services)
    n_rows = (n_services + n_cols - 1) // n_cols
    fig, axes = plt.subplots(n_rows, n_cols, figsize=(4 * n_cols, 3.5 * n_rows))
    if n_services == 1:
        axes = np.array([axes])
    axes = axes.flatten()

    title_base = "10b. Latency to each service by source node (p95)"
    if from_loadgen_only:
        title_base += " (from load generator)"
    else:
        title_base += " (client prober → service)"
    fig.suptitle(title_base + "\nRead: for a given service, each bar = p95 latency when the request came from that node.", fontsize=12, fontweight="bold", y=1.02)

    for idx, ts in enumerate(target_services):
        ax = axes[idx]
        node_p95 = []
        labels = []
        for sn in source_nodes:
            vals = sorted(pair_latencies.get((sn, ts), []))
            if vals:
                p95 = vals[min(int(len(vals) * 0.95), len(vals) - 1)]
                node_p95.append(p95)
                labels.append(short_node(sn))
        if not node_p95:
            ax.text(0.5, 0.5, "No data", ha="center", va="center", transform=ax.transAxes)
            ax.set_title(ts, fontsize=10)
            ax.set_xticks([])
            continue
        colors = ["#2166ac" if i % 2 == 0 else "#4393c3" for i in range(len(labels))]
        ax.bar(range(len(labels)), node_p95, color=colors, alpha=0.85)
        ax.set_xticks(range(len(labels)))
        ax.set_xticklabels(labels, rotation=45, ha="right", fontsize=8)
        ax.set_ylabel("p95 latency (ms)", fontsize=9)
        ax.set_title(ts, fontsize=10, fontweight="bold")
        ax.grid(True, alpha=0.3, axis="y")

    for j in range(n_services, len(axes)):
        axes[j].set_visible(False)
    plt.tight_layout()
    output_path = os.path.join(output_dir, "10b_latency_to_service_by_node.png")
    plt.savefig(output_path, dpi=300, bbox_inches="tight")
    print(f"✓ Generated: {output_path}")
    plt.close()


# ---------------------------------------------------------------------------
# Graph 11 – queueing delay vs network RTT decomposition over time
# ---------------------------------------------------------------------------

def plot_queueing_vs_rtt(s2s_records, output_dir, from_loadgen_only=False):
    """Stacked area: mean network RTT (connect) vs queueing (ttfb − connect) per snapshot."""
    if not s2s_records:
        print("⚠ No s2s data, skipping queueing vs RTT graph")
        return

    by_ts = defaultdict(lambda: {"connect": [], "queueing": []})
    for rec in s2s_records:
        connect = rec.get("connect")
        ttfb = rec.get("ttfb")
        ts = rec.get("timestamp", "")
        if connect is not None and ttfb is not None and connect >= 0:
            q = ttfb - connect
            if q >= 0:
                by_ts[ts]["connect"].append(connect)
                by_ts[ts]["queueing"].append(q)

    if not by_ts:
        print("⚠ No connect/ttfb data for queueing vs RTT graph")
        return

    sorted_ts = sorted(by_ts)
    mean_connect = [np.mean(by_ts[ts]["connect"]) for ts in sorted_ts]
    mean_queueing = [np.mean(by_ts[ts]["queueing"]) for ts in sorted_ts]
    x = range(len(sorted_ts))

    title = "11. Decomposition: network RTT vs server queueing delay over time"
    if from_loadgen_only:
        title += " (from load generator)"
    else:
        title += " (client prober → service)"

    fig, ax = plt.subplots(figsize=(14, 6))
    ax.stackplot(x, mean_connect, mean_queueing,
                 labels=["Network RTT (connect)", "Queueing delay (ttfb − connect)"],
                 colors=["#4393c3", "#d6604d"], alpha=0.85)
    ax.set_xlabel("Probe snapshot (time order)", fontsize=12)
    ax.set_ylabel("Latency (ms)", fontsize=12)
    ax.set_title(title, fontsize=14, fontweight="bold")
    ax.legend(loc="upper left", fontsize=10)
    ax.grid(True, alpha=0.3, axis="y")
    plt.tight_layout()
    output_path = os.path.join(output_dir, "11_queueing_vs_rtt.png")
    plt.savefig(output_path, dpi=300, bbox_inches="tight")
    print(f"✓ Generated: {output_path}")
    plt.close()


# ---------------------------------------------------------------------------
# Graph 11b – network delay only (RTT / connect time over time)
# ---------------------------------------------------------------------------

def plot_network_rtt_only(s2s_records, output_dir, from_loadgen_only=False):
    """Line/area: network RTT (connect time) only over probe snapshots — Y-axis scaled for network delay."""
    if not s2s_records:
        print("⚠ No s2s data, skipping network RTT-only graph")
        return

    by_ts = defaultdict(list)
    for rec in s2s_records:
        connect = rec.get("connect")
        ts = rec.get("timestamp", "")
        if connect is not None and connect >= 0 and ts:
            by_ts[ts].append(connect)

    if not by_ts:
        print("⚠ No connect data for network RTT-only graph")
        return

    sorted_ts = sorted(by_ts)
    mean_connect = [np.mean(by_ts[ts]) for ts in sorted_ts]
    x = range(len(sorted_ts))

    title = "11b. Network delay only: RTT (connect time) over time"
    if from_loadgen_only:
        title += " (from load generator)"
    else:
        title += " (client prober → service)"

    fig, ax = plt.subplots(figsize=(14, 5))
    ax.fill_between(x, mean_connect, alpha=0.4, color="#4393c3")
    ax.plot(x, mean_connect, color="#2166ac", linewidth=2, label="Mean network RTT (connect)")
    ax.set_xlabel("Probe snapshot (time order)", fontsize=12)
    ax.set_ylabel("Network RTT (ms)", fontsize=12)
    ax.set_title(title, fontsize=14, fontweight="bold")
    ax.legend(loc="upper right", fontsize=10)
    ax.grid(True, alpha=0.3, axis="y")
    ax.set_ylim(0, None)  # Start at 0 so network delay is visible on its own scale
    plt.tight_layout()
    output_path = os.path.join(output_dir, "11b_network_rtt_only.png")
    plt.savefig(output_path, dpi=300, bbox_inches="tight")
    print(f"✓ Generated: {output_path}")
    plt.close()


def main():
    parser = argparse.ArgumentParser(
        description="Generate visualization graphs from baseline test data"
    )
    parser.add_argument(
        "data_dir",
        nargs="?",
        help="Path to data directory (e.g., stage1-baseline/data/20260214-191727). "
             "If not provided, uses the latest run."
    )
    parser.add_argument(
        "-o", "--output",
        help="Output directory for graphs (default: <data_dir>/graphs)"
    )
    
    args = parser.parse_args()
    
    # Determine data directory
    if args.data_dir:
        data_dir = args.data_dir
    else:
        # Find latest data directory
        script_dir = Path(__file__).parent
        data_base = script_dir / "data"
        if not data_base.exists():
            print(f"Error: No data directory found at {data_base}")
            sys.exit(1)
        
        run_dirs = sorted([d for d in data_base.iterdir() if d.is_dir()], reverse=True)
        if not run_dirs:
            print(f"Error: No run directories found in {data_base}")
            sys.exit(1)
        
        data_dir = str(run_dirs[0])
        print(f"Using latest run: {os.path.basename(data_dir)}")
    
    if not os.path.exists(data_dir):
        print(f"Error: Data directory not found: {data_dir}")
        sys.exit(1)
    
    # Determine output directory
    if args.output:
        output_dir = args.output
    else:
        output_dir = os.path.join(data_dir, "graphs")
    
    os.makedirs(output_dir, exist_ok=True)
    
    print(f"\nGenerating graphs from: {data_dir}")
    print(f"Output directory: {output_dir}\n")
    
    # Load data
    print("Loading burst data...")
    bursts = load_burst_data(data_dir)
    if not bursts:
        print("Error: No burst data found")
        sys.exit(1)
    print(f"  Loaded {len(bursts)} bursts")
    
    print("Loading pod placement data...")
    snapshots = load_pod_placement_data(data_dir)
    if snapshots:
        print(f"  Loaded {len(snapshots)} snapshots")
    else:
        print("  No pod placement data found")
    
    # Generate graphs in story order (view 01–11 in order to understand the experiment)
    print("\nGenerating graphs (story order: load → response → scaling → placement → network)...")
    plot_qps_comparison(bursts, output_dir)
    plot_latency_percentiles(bursts, output_dir)
    plot_latency_vs_qps(bursts, output_dir)
    if snapshots:
        plot_pod_distribution(snapshots, output_dir)
    placement = load_service_placement(data_dir)
    if placement:
        plot_service_placement(placement, output_dir)
    plot_latency_distribution(bursts, output_dir)
    generate_summary_stats(bursts, snapshots, output_dir)

    print("\nGenerating network graphs 07–11 (always attempted)...")
    s2s_path = os.path.join(data_dir, "network-analysis", "service-to-service-latency.jsonl")
    csv_path = os.path.join(data_dir, "network-analysis", "latency-vs-replicas.csv")
    s2s_records = load_s2s_data(data_dir)
    service_to_nodes = load_service_endpoint_nodes(data_dir)
    latency_replicas_rows = load_latency_vs_replicas(data_dir)
    if s2s_records:
        print(f"  Loaded {len(s2s_records)} s2s probe records")
    else:
        print("  No s2s probe data (07, 08, 10, 11 need service-to-service-latency.jsonl from the run)")
        if not os.path.exists(s2s_path):
            print(f"  ⚠ Missing: {s2s_path}")
            print("    → Create it by running the traffic test (MODE=full or MODE=traffic). Do not delete/copy run without this file.")
    if latency_replicas_rows:
        print(f"  Loaded {len(latency_replicas_rows)} latency-vs-replicas rows")
    else:
        print("  No latency-vs-replicas data (09, 09b need 07-analyze-network-data.py output)")
        if not os.path.exists(csv_path):
            print(f"  ⚠ Missing: {csv_path}")
            print("    → Run 02-analyze-results.sh (or 07-analyze-network-data.py) first; it needs service-to-service-latency.jsonl.")

    def _plot(name, func, *args, **kwargs):
        try:
            func(*args, **kwargs)
        except Exception as e:
            print(f"  ⚠ {name}: {e}")

    # Prefer client/prober → service (exclude load generator) for network graphs
    LOADGEN_SOURCE = "fortio-loadgen"
    s2s_boutique = [r for r in (s2s_records or []) if (r.get("source_pod") or "").strip() != LOADGEN_SOURCE]
    s2s_for_network = s2s_boutique if s2s_boutique else (s2s_records or [])
    from_loadgen_only = bool(s2s_records) and not s2s_boutique

    _plot("07_cross_node_ratio", plot_cross_node_ratio, s2s_for_network, service_to_nodes, output_dir, from_loadgen_only=from_loadgen_only)
    _plot("08_same_vs_cross_node_cdf", plot_same_vs_cross_node_cdf, s2s_for_network, service_to_nodes, output_dir, from_loadgen_only=from_loadgen_only)
    _plot("09_p95_vs_replicas", plot_p95_vs_replicas, latency_replicas_rows, output_dir)
    _plot("09b_p95_vs_node_count", plot_p95_vs_node_count, latency_replicas_rows, output_dir)
    _plot("10_node_pair_heatmap", plot_node_pair_heatmap, s2s_for_network, output_dir, from_loadgen_only=from_loadgen_only)
    _plot("10b_latency_to_service_by_node", plot_latency_to_service_by_node, s2s_for_network, output_dir, from_loadgen_only=from_loadgen_only)
    _plot("11_queueing_vs_rtt", plot_queueing_vs_rtt, s2s_for_network, output_dir, from_loadgen_only=from_loadgen_only)
    _plot("11b_network_rtt_only", plot_network_rtt_only, s2s_for_network, output_dir, from_loadgen_only=from_loadgen_only)

    # Write a short README so viewers know the order
    readme_path = os.path.join(output_dir, "README.txt")
    with open(readme_path, "w") as f:
        f.write("Experiment graphs – view in order to follow the story:\n\n")
        f.write("  01_qps_comparison.png            – Load applied (actual QPS per burst)\n")
        f.write("  02_latency_percentiles.png        – Mean latency percentiles over bursts (+ normalised QPS bg)\n")
        f.write("  03_latency_vs_qps.png             – Latency vs load: does higher QPS increase latency?\n")
        f.write("  04_pod_distribution.png           – Scaling: pod count per node over time\n")
        f.write("  05_service_placement_by_node.png  – Placement: which service's pods are on which node\n")
        f.write("  06_latency_distribution.png       – Summary: latency distribution across bursts\n\n")
        f.write("  Network-inefficiency graphs (require s2s probe data):\n")
        f.write("  07_cross_node_ratio.png           – % of calls that crossed a node boundary per service pair\n")
        f.write("  08_same_vs_cross_node_cdf.png     – Latency CDF: same-node vs cross-node calls\n")
        f.write("  09_p95_vs_replicas.png            – p95 latency vs total running replicas (HPA scaling cost)\n")
        f.write("  09b_p95_vs_node_count.png        – p95 latency vs nodes with pods (cross-node latency cost)\n")
        f.write("  10_node_pair_latency_heatmap.png  – p95 latency heatmap: source node × target service\n")
        f.write("  10b_latency_to_service_by_node.png – Latency to each service by source node (e.g. frontend: from node1, node2, …)\n")
        f.write("  11_queueing_vs_rtt.png            – Decomposition: network RTT vs server queueing delay\n")
        f.write("  11b_network_rtt_only.png          – Network delay only: RTT (connect time) over time\n\n")
        f.write("  summary_stats.txt                 – Numeric summary\n")
    print(f"✓ Generated: {readme_path}")

    print(f"\n✓ All graphs generated in: {output_dir}")
    print("View in order (01 → 11). See graphs/README.txt.")


if __name__ == "__main__":
    main()
