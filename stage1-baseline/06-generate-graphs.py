#!/usr/bin/env python3
"""
Generate visualization graphs from baseline test data.
Produces graphs for latency, QPS, pod placement, and network analysis.
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
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    import matplotlib.patches as mpatches
    import matplotlib.patheffects as pe
    import numpy as np
except ImportError:
    print("Error: matplotlib is required. Install with: pip3 install matplotlib")
    sys.exit(1)

# ---------------------------------------------------------------------------
# Online Boutique service call graph (caller -> [callees])
# ---------------------------------------------------------------------------
BOUTIQUE_CALL_GRAPH = {
    "frontend": [
        "productcatalogservice", "recommendationservice", "cartservice",
        "adservice", "checkoutservice", "currencyservice", "shippingservice",
    ],
    "checkoutservice": [
        "cartservice", "currencyservice", "emailservice",
        "paymentservice", "productcatalogservice", "shippingservice",
    ],
    "recommendationservice": ["productcatalogservice"],
    "cartservice": ["redis-cart"],
}

ENDPOINT_COLORS = {"cart": "#2166ac", "home": "#d6604d", "product": "#4dac26", "all": "#666666"}
ENDPOINT_ORDER  = ["cart", "home", "product"]

BOUTIQUE_SERVICES = [
    "frontend", "productcatalogservice", "recommendationservice", "cartservice",
    "checkoutservice", "paymentservice", "shippingservice", "currencyservice",
]


# ---------------------------------------------------------------------------
# Data loaders
# ---------------------------------------------------------------------------

def load_burst_data(data_dir):
    """Load latency data from all fortio burst files, extracting endpoint label."""
    loadgen_dir = os.path.join(data_dir, "loadgen")
    burst_files = sorted(glob.glob(os.path.join(loadgen_dir, "fortio-burst-*.json")))
    bursts = []
    for file_path in burst_files:
        with open(file_path, 'r') as f:
            data = json.load(f)
        base = os.path.basename(file_path).replace(".json", "").replace("fortio-burst-", "")
        parts = base.split("-")
        try:
            burst_index = int(parts[0])
        except (ValueError, IndexError):
            burst_index = len(bursts)
        endpoint = parts[1] if len(parts) >= 2 else "all"
        percentiles = {p["Percentile"]: p["Value"] for p in
                       data.get("DurationHistogram", {}).get("Percentiles", [])}
        # ConnectionStats: list of per-connection times (seconds)
        conn_stats = data.get("ConnectionStats", {})
        conn_p50 = conn_p95 = None
        for cp in conn_stats.get("Percentiles", []):
            if cp.get("Percentile") == 50:
                conn_p50 = cp["Value"] * 1000  # → ms
            if cp.get("Percentile") == 95:
                conn_p95 = cp["Value"] * 1000
        bursts.append({
            "file": os.path.basename(file_path),
            "index": burst_index,
            "endpoint": endpoint,
            "start_time": data.get("StartTime", ""),
            "requested_qps": float(data.get("RequestedQPS", 0)),
            "actual_qps": data.get("ActualQPS", 0),
            "duration_s": data.get("ActualDuration", 0) / 1e9,
            "p50":  percentiles.get(50,   0),
            "p90":  percentiles.get(90,   0),
            "p95":  percentiles.get(95,   0),
            "p99":  percentiles.get(99,   0),
            "p999": percentiles.get(99.9, 0),
            "avg":  data.get("DurationHistogram", {}).get("Avg", 0),
            "count": data.get("DurationHistogram", {}).get("Count", 0),
            "conn_p50_ms": conn_p50,
            "conn_p95_ms": conn_p95,
            # Raw connection time samples (seconds → ms) for CDF
            "conn_times_ms": [
                entry["Start"] * 1000
                for entry in conn_stats.get("Data", [])
                for _ in range(int(entry.get("Count", 0)))
            ],
        })
    return sorted(bursts, key=lambda x: (x["index"], x["file"]))


def load_bursts_jsonl(data_dir):
    """Load loadgen/bursts.jsonl — contains configured QPS per burst."""
    path = os.path.join(data_dir, "loadgen", "bursts.jsonl")
    if not os.path.exists(path):
        return []
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    rows.append(json.loads(line))
                except Exception:
                    pass
    return rows


def load_pod_placement_data(data_dir):
    """Load pod placement snapshots; prefer pod-placement/, fall back to pod-network-*.json."""
    placement_dir = os.path.join(data_dir, "pod-placement")
    network_dir   = os.path.join(data_dir, "network-analysis")
    if os.path.exists(placement_dir):
        index_file = os.path.join(placement_dir, "index.jsonl")
        if os.path.exists(index_file):
            snapshots = []
            with open(index_file, 'r') as f:
                for line in f:
                    entry = json.loads(line.strip())
                    sf = os.path.join(placement_dir, entry["file"])
                    if not os.path.exists(sf):
                        continue
                    with open(sf, 'r') as fh:
                        snap = json.load(fh)
                    nc = defaultdict(int)
                    for pod in snap.get("items", []):
                        if pod.get("metadata", {}).get("namespace") == "default":
                            node = pod.get("spec", {}).get("nodeName", "unknown")
                            if node and node != "unknown":
                                nc[node] += 1
                    snapshots.append({"timestamp": entry["timestamp"],
                                      "index": int(entry["file"].replace("pods-", "").replace(".json", "")),
                                      "node_counts": dict(nc)})
            if snapshots:
                return sorted(snapshots, key=lambda x: x["index"])
    if os.path.exists(network_dir):
        pod_files = sorted(glob.glob(os.path.join(network_dir, "pod-network-*.json")))
        snapshots = []
        for i, fp in enumerate(pod_files):
            with open(fp) as f:
                snap = json.load(f)
            stem = os.path.basename(fp).replace("pod-network-", "").replace(".json", "")
            nc = defaultdict(int)
            for pod in snap.get("items", []):
                if pod.get("metadata", {}).get("namespace") == "default":
                    node = pod.get("spec", {}).get("nodeName", "unknown")
                    if node and node != "unknown":
                        nc[node] += 1
            snapshots.append({"timestamp": stem, "index": i, "node_counts": dict(nc)})
        if snapshots:
            return snapshots
    return None


def load_service_placement(data_dir):
    path = os.path.join(data_dir, "network-analysis", "pod-placement-analysis.json")
    if not os.path.exists(path):
        return None
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None


def load_s2s_data(data_dir):
    """Load service-to-service probe records."""
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
    """Return {service_name: set(node_names)} from service-endpoints-*.json."""
    network_dir = os.path.join(data_dir, "network-analysis")
    svc_nodes = defaultdict(set)
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
                        svc_nodes[svc].add(node)
    return {k: v for k, v in svc_nodes.items()}


def load_latency_vs_replicas(data_dir):
    """Load network-analysis/latency-vs-replicas.csv."""
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
# Helpers
# ---------------------------------------------------------------------------

def short_node(n):
    return n.split(".")[0] if n else n


def detect_warmup_burst(bursts):
    """Return the first burst index considered 'steady-state' (warm-up ends here).
    Uses heuristic: steady-state starts when p95 drops below 2× its trailing median.
    Returns the burst index (inclusive) where steady-state begins.
    """
    p95s = [b["p95"] * 1000 for b in bursts]
    if len(p95s) < 4:
        return 0
    # Trailing median from the back half
    back_half = sorted(p95s[len(p95s)//2:])
    steady_p95 = back_half[len(back_half)//2]
    threshold = steady_p95 * 2.0
    for i, v in enumerate(p95s):
        if v <= threshold:
            return i
    return len(p95s) - 1


def _save(fig, output_dir, filename):
    path = os.path.join(output_dir, filename)
    fig.savefig(path, dpi=150, bbox_inches="tight")
    print(f"✓ Generated: {path}")
    plt.close(fig)


# ---------------------------------------------------------------------------
# Graph 01 – QPS: actual vs configured, colored by endpoint
# ---------------------------------------------------------------------------

def plot_qps_comparison(bursts, output_dir, bursts_config=None):
    """Bar chart: actual QPS per burst, bars colored by endpoint (cart/home/product).
    Overlays configured QPS from bursts.jsonl when available.
    """
    # Group by endpoint
    by_endpoint = defaultdict(list)
    for b in bursts:
        by_endpoint[b["endpoint"]].append(b)

    endpoints = [e for e in ENDPOINT_ORDER if e in by_endpoint]
    if not endpoints:
        endpoints = sorted(by_endpoint.keys())

    # All burst indices (some may appear once per endpoint)
    all_indices = sorted({b["index"] for b in bursts})
    x = np.arange(len(all_indices))
    n_ep = len(endpoints)
    width = 0.8 / max(n_ep, 1)

    fig, ax = plt.subplots(figsize=(max(12, len(all_indices) * 0.55), 5))

    for k, ep in enumerate(endpoints):
        ep_map = {b["index"]: b["actual_qps"] for b in by_endpoint[ep]}
        vals = [ep_map.get(i, 0) for i in all_indices]
        offset = (k - (n_ep - 1) / 2) * width
        ax.bar(x + offset, vals, width=width,
               color=ENDPOINT_COLORS.get(ep, "#888888"), alpha=0.85, label=ep)

    # Configured QPS overlay (per burst index, divided by n_endpoints as rough per-endpoint share)
    if bursts_config:
        cfg_map = {r["burst_index"]: r.get("total_qps", 0) / max(n_ep, 1) for r in bursts_config}
        cfg_vals = [cfg_map.get(i, None) for i in all_indices]
        valid = [(x[j], cfg_vals[j]) for j in range(len(all_indices)) if cfg_vals[j] is not None]
        if valid:
            xs, ys = zip(*valid)
            ax.plot(xs, ys, 'k--', linewidth=1.5, label="Configured QPS / endpoint", alpha=0.6)

    ax.set_xlabel("Burst index", fontsize=12)
    ax.set_ylabel("Queries per second (QPS)", fontsize=12)
    ax.set_title("1. Load: actual QPS per burst, by endpoint\n"
                 "(Dashed line = configured QPS ÷ endpoints — gap shows cluster capacity limit)",
                 fontsize=13, fontweight="bold")
    ax.set_xticks(x)
    ax.set_xticklabels([str(i) for i in all_indices], fontsize=8)
    ax.legend(loc="upper left", fontsize=10)
    ax.grid(True, alpha=0.3, axis="y")
    plt.tight_layout()
    _save(fig, output_dir, "01_qps_comparison.png")


# ---------------------------------------------------------------------------
# Graph 02 – Latency percentiles per endpoint over bursts
# ---------------------------------------------------------------------------

def plot_latency_percentiles(bursts, output_dir):
    """Per-endpoint p95 lines over burst index, with warm-up phase annotated."""
    by_ep = defaultdict(dict)
    for b in bursts:
        by_ep[b["endpoint"]][b["index"]] = b

    endpoints = [e for e in ENDPOINT_ORDER if e in by_ep]
    if not endpoints:
        endpoints = sorted(by_ep.keys())

    all_idx = sorted({b["index"] for b in bursts})
    warmup_end = detect_warmup_burst(bursts)

    fig, axes = plt.subplots(len(endpoints), 1,
                             figsize=(14, 3.5 * len(endpoints)),
                             sharex=True)
    if len(endpoints) == 1:
        axes = [axes]

    for ax, ep in zip(axes, endpoints):
        idx_to_burst = by_ep[ep]
        idx_list = sorted(idx_to_burst.keys())
        p50  = [idx_to_burst[i]["p50"]  * 1000 for i in idx_list]
        p95  = [idx_to_burst[i]["p95"]  * 1000 for i in idx_list]
        p99  = [idx_to_burst[i]["p99"]  * 1000 for i in idx_list]
        qps  = [idx_to_burst[i]["actual_qps"] for i in idx_list]
        max_qps = max(qps) if qps else 1

        # Background QPS
        ax2 = ax.twinx()
        ax2.bar(idx_list, qps, color="grey", alpha=0.15, width=0.8, zorder=1)
        ax2.set_ylim(0, max_qps * 3.5)
        ax2.set_yticks([0, max_qps / 2, max_qps])
        ax2.set_yticklabels(["0", f"{max_qps/2:.0f}", f"{max_qps:.0f} QPS"],
                             fontsize=8, color="grey")
        ax2.set_ylabel("QPS", fontsize=8, color="grey")
        ax2.tick_params(axis="y", colors="grey")

        # Warm-up shading
        if warmup_end > 0 and idx_list:
            ax.axvspan(idx_list[0] - 0.5, warmup_end - 0.5,
                       color="#ffe0b2", alpha=0.45, zorder=0, label="Warm-up (HPA scaling)")
            ax.axvline(warmup_end - 0.5, color="#e65100", linewidth=1.2,
                       linestyle="--", alpha=0.7)
            ax.text(warmup_end - 0.3, ax.get_ylim()[1] * 0.02,
                    "HPA stabilised →", fontsize=8, color="#e65100", va="bottom")

        c = ENDPOINT_COLORS.get(ep, "#444")
        ax.plot(idx_list, p50,  "o-",  color=c,          linewidth=1.5, markersize=4, label="p50",  alpha=0.6)
        ax.plot(idx_list, p95,  "s-",  color=c,          linewidth=2,   markersize=5, label="p95")
        ax.plot(idx_list, p99,  "^--", color=c,          linewidth=1.5, markersize=4, label="p99",  alpha=0.7)

        ax.set_ylabel("Latency (ms)", fontsize=11)
        ax.set_title(f"/{ep} endpoint", fontsize=11, fontweight="bold", loc="left")
        ax.legend(loc="upper right", fontsize=9)
        ax.grid(True, alpha=0.3, zorder=2)
        ax.set_zorder(ax2.get_zorder() + 1)
        ax.patch.set_visible(False)

    axes[-1].set_xlabel("Burst index", fontsize=12)
    fig.suptitle("2. Response: latency percentiles per endpoint over traffic bursts\n"
                 "(Shaded = HPA warm-up; lines = p50/p95/p99; bars = QPS)",
                 fontsize=13, fontweight="bold", y=1.01)
    plt.tight_layout()
    _save(fig, output_dir, "02_latency_percentiles.png")


# ---------------------------------------------------------------------------
# Graph 03 – Latency vs QPS scatter, colored by phase
# ---------------------------------------------------------------------------

def plot_latency_vs_qps(bursts, output_dir):
    """Scatter: latency vs actual QPS, colored by warm-up (orange) vs steady-state (blue).
    The negative correlation in warm-up is an HPA artifact, not a true load effect.
    """
    warmup_end = detect_warmup_burst(bursts)

    fig, ax = plt.subplots(figsize=(11, 6))

    for phase, label, color, marker in [
        ("warmup",  f"Warm-up phase (bursts 0–{warmup_end-1})", "#e65100", "^"),
        ("steady",  f"Steady-state (bursts {warmup_end}+)",       "#2166ac", "o"),
    ]:
        qps, p95, p99 = [], [], []
        for b in bursts:
            is_warmup = b["index"] < warmup_end
            if (phase == "warmup" and is_warmup) or (phase == "steady" and not is_warmup):
                qps.append(b["actual_qps"])
                p95.append(b["p95"] * 1000)
                p99.append(b["p99"] * 1000)
        if qps:
            ax.scatter(qps, p95, alpha=0.75, s=55, color=color, marker=marker,
                       label=f"{label} — p95")
            ax.scatter(qps, p99, alpha=0.45, s=35, color=color, marker="x",
                       label=f"{label} — p99")

    ax.set_xlabel("Actual QPS", fontsize=12)
    ax.set_ylabel("Latency (ms)", fontsize=12)
    ax.set_title("3. Latency vs load: warm-up phase vs steady-state\n"
                 "(Apparent negative slope in warm-up is an HPA scaling artifact, "
                 "not a true load effect — filter to steady-state only for analysis)",
                 fontsize=12, fontweight="bold")
    ax.legend(loc="upper right", fontsize=9)
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    _save(fig, output_dir, "03_latency_vs_qps.png")


# ---------------------------------------------------------------------------
# Graph 04 – Pod distribution per node over time
# ---------------------------------------------------------------------------

def plot_pod_distribution(snapshots, output_dir):
    """Stacked area: pod count per node over snapshots, with imbalance annotation."""
    if not snapshots:
        print("⚠ No pod placement data, skipping graph 04")
        return

    all_nodes = sorted({n for s in snapshots for n in s["node_counts"]})
    indices = [s["index"] for s in snapshots]
    node_data = {n: [s["node_counts"].get(n, 0) for s in snapshots] for n in all_nodes}
    short_labels = [short_node(n) for n in all_nodes]

    fig, (ax, ax2) = plt.subplots(2, 1, figsize=(14, 8),
                                   gridspec_kw={"height_ratios": [3, 1]})

    colors = plt.cm.tab10(np.linspace(0, 0.9, len(all_nodes)))
    ax.stackplot(indices, *[node_data[n] for n in all_nodes],
                 labels=short_labels, alpha=0.8, colors=colors)
    ax.set_ylabel("Total pods", fontsize=12)
    ax.set_title("4. Scaling: pod count per node over time\n"
                 "(Stacked area = all pods; bottom panel = balance ratio max/min)",
                 fontsize=13, fontweight="bold")
    ax.legend(loc="upper left", fontsize=9, bbox_to_anchor=(1.01, 1))
    ax.grid(True, alpha=0.3, axis="y")

    # Imbalance ratio: max pods / min pods across nodes (ignoring zeros)
    ratios = []
    for s in snapshots:
        counts = [v for v in s["node_counts"].values() if v > 0]
        ratios.append(max(counts) / min(counts) if len(counts) >= 2 else 1.0)
    ax2.plot(indices, ratios, color="#d6604d", linewidth=2)
    ax2.fill_between(indices, 1, ratios, alpha=0.3, color="#d6604d")
    ax2.axhline(1.0, color="green", linewidth=1, linestyle="--", alpha=0.6, label="Perfect balance")
    ax2.set_ylabel("Imbalance\n(max/min pods)", fontsize=10)
    ax2.set_xlabel("Snapshot index", fontsize=12)
    ax2.set_ylim(0.8, None)
    ax2.legend(fontsize=9)
    ax2.grid(True, alpha=0.3, axis="y")

    plt.tight_layout()
    _save(fig, output_dir, "04_pod_distribution.png")


# ---------------------------------------------------------------------------
# Graph 05 – Service placement heatmap + call graph co-location overlay
# ---------------------------------------------------------------------------

def plot_service_placement(placement, output_dir):
    """Heatmap: service × node pod counts, with call graph edges showing
    cross-node (red) vs potentially same-node (green) call paths."""
    spread = (placement.get("service_node_spread_avg") or
              placement.get("service_node_spread")) if placement else None
    if not spread:
        print("⚠ No service_node_spread, skipping graph 05")
        return

    use_avg = bool(placement.get("service_node_spread_avg"))
    services = sorted(spread.keys())
    all_nodes = set()
    for info in spread.values():
        all_nodes.update(info.get("nodes_used", []))
    nodes = sorted(all_nodes)
    node_labels = [short_node(n) for n in nodes]

    data = []
    for svc in services:
        counts = (spread[svc].get("pod_count_by_node") or
                  spread[svc].get("samples_per_node", {}))
        data.append([counts.get(n, 0) for n in nodes])

    if not data or not nodes:
        print("⚠ No placement matrix data, skipping graph 05")
        return

    # ---- figure: heatmap on top, call-graph co-location legend below ----
    fig = plt.figure(figsize=(max(9, len(nodes) * 1.6), max(8, len(services) * 0.45) + 3))
    ax_heat = fig.add_axes([0.15, 0.30, 0.72, 0.65])
    ax_legend = fig.add_axes([0.02, 0.00, 0.96, 0.26])

    vmax = max(max(r) for r in data) or 1
    im = ax_heat.imshow(data, cmap="Blues", aspect="auto", vmin=0, vmax=vmax)
    ax_heat.set_xticks(range(len(nodes)))
    ax_heat.set_xticklabels(node_labels, rotation=45, ha="right")
    ax_heat.set_yticks(range(len(services)))
    ax_heat.set_yticklabels(services, fontsize=9)
    ax_heat.set_xlabel("Node", fontsize=11)
    ax_heat.set_ylabel("Service", fontsize=11)
    ax_heat.set_title("5. Placement: service pods per node  (avg over all snapshots)\n"
                      "Call graph below: green = co-located on same node possible, "
                      "red = always cross-node",
                      fontsize=12, fontweight="bold")
    plt.colorbar(im, ax=ax_heat,
                 label="Pod count (avg over snapshots)", fraction=0.03, pad=0.02)

    for i in range(len(services)):
        for j in range(len(nodes)):
            v = data[i][j]
            if v > 0:
                label = (f"{v:.1f}" if use_avg and isinstance(v, float) and v != int(v)
                         else str(int(round(v))))
                ax_heat.text(j, i, label, ha="center", va="center",
                             color="white" if v >= vmax / 2 else "black", fontsize=9)

    # Overlay arrows for call graph edges on the LEFT margin
    svc_row = {s: i for i, s in enumerate(services)}
    arrow_props = dict(arrowstyle="->", lw=1.2, connectionstyle="arc3,rad=0.3")
    for caller, callees in BOUTIQUE_CALL_GRAPH.items():
        if caller not in svc_row:
            continue
        for callee in callees:
            if callee not in svc_row:
                continue
            caller_nodes = set(spread.get(caller, {}).get("nodes_used", []))
            callee_nodes = set(spread.get(callee, {}).get("nodes_used", []))
            co_located = bool(caller_nodes & callee_nodes)
            color = "#2ca02c" if co_located else "#d62728"
            y0 = svc_row[caller]
            y1 = svc_row[callee]
            ax_heat.annotate("",
                xy=(-0.7, y1), xytext=(-0.7, y0),
                xycoords="data", textcoords="data",
                arrowprops={**arrow_props, "color": color},
                annotation_clip=False)

    # Call-graph summary table
    ax_legend.axis("off")
    lines = []
    for caller, callees in BOUTIQUE_CALL_GRAPH.items():
        for callee in callees:
            caller_nodes = set(spread.get(caller, {}).get("nodes_used", []))
            callee_nodes = set(spread.get(callee, {}).get("nodes_used", []))
            co = bool(caller_nodes & callee_nodes)
            label = "same-node possible" if co else "ALWAYS CROSS-NODE"
            color = "#2ca02c" if co else "#d62728"
            lines.append((f"{caller} → {callee}", label, color))

    n_cols = 3
    col_width = 1.0 / n_cols
    for idx, (edge, label, color) in enumerate(lines):
        col = idx % n_cols
        row = idx // n_cols
        x_pos = col * col_width + 0.01
        y_pos = 0.92 - row * 0.22
        ax_legend.text(x_pos, y_pos, f"{edge}:  ", ha="left", va="top",
                       fontsize=8.5, transform=ax_legend.transAxes)
        ax_legend.text(x_pos + 0.16, y_pos, label, ha="left", va="top",
                       fontsize=8.5, color=color, fontweight="bold",
                       transform=ax_legend.transAxes)

    ax_legend.set_title("Call graph co-location status  "
                        "(green = caller & callee share a node, red = always cross-node)",
                        fontsize=10, loc="left", pad=4)

    _save(fig, output_dir, "05_service_placement_by_node.png")


# ---------------------------------------------------------------------------
# Graph 06 – Latency distribution, split by endpoint
# ---------------------------------------------------------------------------

def plot_latency_distribution(bursts, output_dir):
    """Box plots of latency distribution split by endpoint (cart / home / product)."""
    by_ep = defaultdict(list)
    for b in bursts:
        by_ep[b["endpoint"]].append(b)

    endpoints = [e for e in ENDPOINT_ORDER if e in by_ep]
    if not endpoints:
        endpoints = sorted(by_ep.keys())

    n_ep = len(endpoints)
    fig, axes = plt.subplots(1, n_ep, figsize=(5 * n_ep, 6), sharey=True)
    if n_ep == 1:
        axes = [axes]

    for ax, ep in zip(axes, endpoints):
        ep_bursts = by_ep[ep]
        data_by_pct = {
            "p50":  [b["p50"]  * 1000 for b in ep_bursts],
            "p95":  [b["p95"]  * 1000 for b in ep_bursts],
            "p99":  [b["p99"]  * 1000 for b in ep_bursts],
            "p99.9":[b["p999"] * 1000 for b in ep_bursts],
        }
        colors = ["lightblue", "lightgreen", "lightyellow", "lightcoral"]
        bp = ax.boxplot(list(data_by_pct.values()),
                        tick_labels=list(data_by_pct.keys()),
                        patch_artist=True, showmeans=True)
        for patch, color in zip(bp["boxes"], colors):
            patch.set_facecolor(color)
        c = ENDPOINT_COLORS.get(ep, "#444")
        ax.set_title(f"/{ep}", fontsize=12, fontweight="bold", color=c)
        ax.grid(True, alpha=0.3, axis="y")
        if ax is axes[0]:
            ax.set_ylabel("Latency (ms)", fontsize=11)

    fig.suptitle("6. Latency distribution by endpoint  (box = IQR, whiskers = 1.5×IQR, △ = mean)\n"
                 "Home endpoint shows consistently higher latency — more downstream service calls",
                 fontsize=13, fontweight="bold")
    plt.tight_layout()
    _save(fig, output_dir, "06_latency_distribution.png")


# ---------------------------------------------------------------------------
# Graph 07 – Cross-node call ratio
# ---------------------------------------------------------------------------

def plot_cross_node_ratio(s2s_records, service_to_nodes, output_dir, from_loadgen_only=False):
    if not s2s_records:
        print("⚠ No s2s data, skipping graph 07")
        return

    def pod_to_app(name):
        parts = name.rsplit("-", 2)
        base = parts[0] if len(parts) >= 2 else name
        if (base or "").lower() == "s2s" or (name or "").startswith("s2s-prober"):
            return "prober"
        return base

    pair_counts = defaultdict(lambda: {"total": 0, "cross": 0})
    for rec in s2s_records:
        sn = rec.get("source_node", "unknown")
        ts = rec.get("target_service", "unknown")
        src = pod_to_app(rec.get("source_pod", "unknown"))
        pair = f"{src}→{ts}"
        target_nodes = service_to_nodes.get(ts, set())
        pair_counts[pair]["total"] += 1
        if sn not in target_nodes:
            pair_counts[pair]["cross"] += 1

    if not pair_counts:
        print("⚠ No pair data for graph 07")
        return

    src_apps = sorted({p.split("→", 1)[0] for p in pair_counts})
    pairs = []
    for src in src_apps:
        for svc in BOUTIQUE_SERVICES:
            pairs.append(f"{src}→{svc}")
    if not any(p in pair_counts for p in pairs):
        pairs = sorted(pair_counts, key=lambda p: pair_counts[p]["cross"] / max(pair_counts[p]["total"], 1), reverse=True)

    def _ratio(p):
        c = pair_counts.get(p, {"total": 0, "cross": 0})
        return c["cross"] / max(c["total"], 1) * 100
    ratios = [_ratio(p) for p in pairs]
    colors = ["#d73027" if r > 75 else "#fc8d59" if r > 40 else "#91bfdb" for r in ratios]

    title = "7. Network: cross-node call ratio per service pair"
    if from_loadgen_only:
        title += " (from load generator — deploy s2s-prober for per-service view)"

    fig, ax = plt.subplots(figsize=(max(10, len(pairs) * 0.6), 6))
    ax.bar(range(len(pairs)), ratios, color=colors, alpha=0.88)
    ax.axhline(50, color="red", linestyle="--", linewidth=1, alpha=0.5, label="50% threshold")
    ax.axhline(100, color="#8b0000", linestyle=":", linewidth=1, alpha=0.4, label="100% (always cross-node)")
    ax.set_xticks(range(len(pairs)))
    ax.set_xticklabels(pairs, rotation=45, ha="right", fontsize=8)
    ax.set_ylabel("Cross-node calls (%)", fontsize=12)
    ax.set_ylim(0, 110)
    ax.set_title(title + "\n(Red = >75% cross-node; orange = 40–75%; blue = <40%)",
                 fontsize=13, fontweight="bold")
    ax.legend(fontsize=10)
    ax.grid(True, alpha=0.3, axis="y")
    plt.tight_layout()
    _save(fig, output_dir, "07_cross_node_ratio.png")


# ---------------------------------------------------------------------------
# Graph 08 – Same-node vs cross-node latency CDF
# ---------------------------------------------------------------------------

def plot_same_vs_cross_node_cdf(s2s_records, service_to_nodes, output_dir, from_loadgen_only=False):
    if not s2s_records:
        print("⚠ No s2s data, skipping graph 08")
        return

    # Filter to successful probes only (code=200 or code not present)
    same_node, cross_node = [], []
    for rec in s2s_records:
        total = rec.get("total")
        code  = rec.get("code")
        if total is None:
            continue
        if code is not None and int(code) != 200:
            continue
        sn = rec.get("source_node", "unknown")
        tnodes = service_to_nodes.get(rec.get("target_service", ""), set())
        if sn == "unknown" or not tnodes:
            continue
        if sn in tnodes:
            same_node.append(total)
        else:
            cross_node.append(total)

    if not same_node and not cross_node:
        print("⚠ No latency data for graph 08")
        return

    fig, ax = plt.subplots(figsize=(10, 6))
    for latencies, label, color in [
        (same_node,  f"Same-node  (n={len(same_node)})",  "#2166ac"),
        (cross_node, f"Cross-node (n={len(cross_node)})", "#d6604d"),
    ]:
        if latencies:
            sv = np.sort(latencies)
            ax.plot(sv, np.arange(1, len(sv) + 1) / len(sv),
                    linewidth=2.5, label=label, color=color)

    ax.set_xlabel("Total latency (ms)", fontsize=12)
    ax.set_ylabel("CDF", fontsize=12)
    ax.set_ylim(0, 1.05)
    title = "8. Network penalty: same-node vs cross-node latency CDF"
    if from_loadgen_only:
        title += " (from load generator)"
    ax.set_title(title + "\n(Same-node = caller & service on same host; CDF = fraction of requests ≤ x ms)",
                 fontsize=12, fontweight="bold")
    ax.legend(fontsize=11)
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    _save(fig, output_dir, "08_same_vs_cross_node_cdf.png")


# ---------------------------------------------------------------------------
# Graph 09 – p95 vs replica count scatter
# ---------------------------------------------------------------------------

def plot_p95_vs_replicas(latency_replicas_rows, output_dir):
    if not latency_replicas_rows:
        print("⚠ No latency-vs-replicas data, skipping graph 09")
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
        cur = sum(int(v) for k, v in row.items()
                  if k.endswith("_current") and v and v.isdigit())
        if cur > 0:
            total_replicas.append(cur)
            p95_vals.append(p95)
    if not total_replicas:
        print("⚠ No data points for graph 09")
        return
    fig, ax = plt.subplots(figsize=(10, 6))
    sc = ax.scatter(total_replicas, p95_vals, c=range(len(total_replicas)),
                    cmap="plasma", alpha=0.75, s=60, edgecolors="none")
    plt.colorbar(sc, ax=ax, label="Time order (darker = earlier)")
    ax.set_xlabel("Total current replicas (all services)", fontsize=12)
    ax.set_ylabel("s2s p95 latency (ms)", fontsize=12)
    ax.set_title(f"9. Scaling cost: p95 latency vs total running replicas\n"
                 f"Replicas: {min(total_replicas)}–{max(total_replicas)}",
                 fontsize=13, fontweight="bold")
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    _save(fig, output_dir, "09_p95_vs_replicas.png")


# ---------------------------------------------------------------------------
# Graph 09b – p95 vs node count
# ---------------------------------------------------------------------------

def plot_p95_vs_node_count(latency_replicas_rows, output_dir):
    node_counts, p95_vals = [], []
    for row in latency_replicas_rows:
        nc_s = row.get("node_count", "").strip()
        p95_s = row.get("s2s_p95_ms", "").strip()
        if not nc_s or not p95_s:
            continue
        try:
            nc, p95 = int(nc_s), float(p95_s)
        except ValueError:
            continue
        if nc > 0:
            node_counts.append(nc)
            p95_vals.append(p95)
    if not node_counts:
        print("⚠ No node_count data, skipping graph 09b")
        return
    nc_min, nc_max = min(node_counts), max(node_counts)
    if nc_min == nc_max:
        print(f"⚠ Skipping graph 09b: node count is constant ({nc_min}) in this run")
        return
    fig, ax = plt.subplots(figsize=(10, 6))
    sc = ax.scatter(node_counts, p95_vals, c=range(len(node_counts)),
                    cmap="viridis", alpha=0.75, s=60, edgecolors="none")
    plt.colorbar(sc, ax=ax, label="Time order")
    ax.set_xlabel("Number of nodes with workload pods", fontsize=12)
    ax.set_ylabel("s2s p95 latency (ms)", fontsize=12)
    ax.set_title(f"9b. Cross-node cost: p95 latency vs pod spread\n"
                 f"Node count range: {nc_min}–{nc_max}",
                 fontsize=13, fontweight="bold")
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    _save(fig, output_dir, "09b_p95_vs_node_count.png")


# ---------------------------------------------------------------------------
# Graph 10 – Node-pair p95 heatmap
# ---------------------------------------------------------------------------

def plot_node_pair_heatmap(s2s_records, output_dir, from_loadgen_only=False):
    if not s2s_records:
        print("⚠ No s2s data, skipping graph 10")
        return
    pair_latencies = defaultdict(list)
    for rec in s2s_records:
        total = rec.get("total")
        sn = rec.get("source_node", "unknown")
        ts = rec.get("target_service", "unknown")
        if total is not None and sn != "unknown":
            pair_latencies[(sn, ts)].append(total)
    if not pair_latencies:
        print("⚠ No data for graph 10")
        return
    src_nodes = sorted({k[0] for k in pair_latencies})
    tgt_svcs  = sorted({k[1] for k in pair_latencies})
    matrix = np.full((len(src_nodes), len(tgt_svcs)), np.nan)
    for i, sn in enumerate(src_nodes):
        for j, ts in enumerate(tgt_svcs):
            vals = sorted(pair_latencies.get((sn, ts), []))
            if vals:
                matrix[i][j] = vals[min(int(len(vals) * 0.95), len(vals) - 1)]
    fig, ax = plt.subplots(figsize=(max(10, len(tgt_svcs) * 0.9), max(4, len(src_nodes) * 0.9)))
    masked = np.ma.masked_invalid(matrix)
    im = ax.imshow(masked, cmap="YlOrRd", aspect="auto")
    plt.colorbar(im, ax=ax, label="p95 latency (ms)")
    ax.set_xticks(range(len(tgt_svcs)))
    ax.set_xticklabels(tgt_svcs, rotation=45, ha="right", fontsize=9)
    ax.set_yticks(range(len(src_nodes)))
    ax.set_yticklabels([short_node(n) for n in src_nodes], fontsize=9)
    ax.set_xlabel("Target service", fontsize=12)
    ax.set_ylabel("Source node", fontsize=12)
    title = "10. Topology: p95 latency heatmap — source node × target service"
    title += " (load generator)" if from_loadgen_only else " (client prober → service)"
    ax.set_title(title, fontsize=13, fontweight="bold")
    vmax = np.nanmax(matrix) if not np.all(np.isnan(matrix)) else 1
    for i in range(len(src_nodes)):
        for j in range(len(tgt_svcs)):
            v = matrix[i][j]
            if not np.isnan(v):
                ax.text(j, i, f"{v:.0f}", ha="center", va="center",
                        fontsize=7, color="white" if v > vmax * 0.6 else "black")
    plt.tight_layout()
    _save(fig, output_dir, "10_node_pair_latency_heatmap.png")


# ---------------------------------------------------------------------------
# Graph 10b – Latency to each service by source node (annotates gRPC failures)
# ---------------------------------------------------------------------------

def _is_grpc_probe_failure(latencies, codes):
    """True if the probe could not speak to this service (all timeouts, code=000)."""
    if not latencies:
        return False
    pct_timeout = sum(1 for v in latencies if v > 4990) / len(latencies)
    if codes:
        pct_fail = sum(1 for c in codes if int(c) != 200) / len(codes)
        return pct_fail > 0.85
    return pct_timeout > 0.85


def plot_latency_to_service_by_node(s2s_records, output_dir, from_loadgen_only=False):
    if not s2s_records:
        print("⚠ No s2s data, skipping graph 10b")
        return

    pair_latencies = defaultdict(list)
    pair_codes     = defaultdict(list)
    for rec in s2s_records:
        total = rec.get("total")
        sn = rec.get("source_node", "unknown")
        ts = rec.get("target_service", "unknown")
        code = rec.get("code")
        if total is not None and sn != "unknown" and ts:
            pair_latencies[(sn, ts)].append(total)
            if code is not None:
                pair_codes[(sn, ts)].append(code)
    if not pair_latencies:
        print("⚠ No data for graph 10b")
        return

    src_nodes = sorted({k[0] for k in pair_latencies})
    tgt_svcs  = [s for s in BOUTIQUE_SERVICES if s in {k[1] for k in pair_latencies}]
    if not tgt_svcs:
        tgt_svcs = sorted({k[1] for k in pair_latencies})

    n_s = len(tgt_svcs)
    n_cols = min(4, n_s)
    n_rows = (n_s + n_cols - 1) // n_cols
    fig, axes = plt.subplots(n_rows, n_cols, figsize=(4.5 * n_cols, 3.8 * n_rows))
    if n_s == 1:
        axes = np.array([axes])
    axes = axes.flatten()

    title_base = "10b. Latency to each service by source node (p95)"
    title_base += " (load generator)" if from_loadgen_only else " (client prober → service)"
    fig.suptitle(title_base +
                 "\nGrey panels: gRPC services cannot be probed via HTTP — deploy gRPC prober",
                 fontsize=12, fontweight="bold", y=1.02)

    for idx, ts in enumerate(tgt_svcs):
        ax = axes[idx]
        node_p95, labels, is_failure = [], [], False
        for sn in src_nodes:
            vals = pair_latencies.get((sn, ts), [])
            codes = pair_codes.get((sn, ts), [])
            if vals:
                fail = _is_grpc_probe_failure(vals, codes)
                if fail:
                    is_failure = True
                    break
                p95 = sorted(vals)[min(int(len(vals) * 0.95), len(vals) - 1)]
                node_p95.append(p95)
                labels.append(short_node(sn))

        if is_failure or not node_p95:
            ax.set_facecolor("#f0f0f0")
            ax.text(0.5, 0.6, ts, ha="center", va="center",
                    transform=ax.transAxes, fontsize=11, fontweight="bold", color="#333")
            ax.text(0.5, 0.40, "gRPC service", ha="center", va="center",
                    transform=ax.transAxes, fontsize=9, color="#c00000")
            ax.text(0.5, 0.25, "HTTP probe not supported", ha="center", va="center",
                    transform=ax.transAxes, fontsize=8, color="#888")
            ax.text(0.5, 0.12, "→ Deploy gRPC prober", ha="center", va="center",
                    transform=ax.transAxes, fontsize=8, color="#888", style="italic")
            ax.set_xticks([])
            ax.set_yticks([])
        else:
            colors_bar = ["#2166ac" if i % 2 == 0 else "#4393c3" for i in range(len(labels))]
            ax.bar(range(len(labels)), node_p95, color=colors_bar, alpha=0.85)
            ax.set_xticks(range(len(labels)))
            ax.set_xticklabels(labels, rotation=45, ha="right", fontsize=8)
            ax.set_ylabel("p95 latency (ms)", fontsize=9)
            ax.set_title(ts, fontsize=10, fontweight="bold")
            ax.grid(True, alpha=0.3, axis="y")

    for j in range(n_s, len(axes)):
        axes[j].set_visible(False)
    plt.tight_layout()
    _save(fig, output_dir, "10b_latency_to_service_by_node.png")


# ---------------------------------------------------------------------------
# Graph 11 – Queueing vs RTT decomposition
# ---------------------------------------------------------------------------

def plot_queueing_vs_rtt(s2s_records, output_dir, from_loadgen_only=False):
    if not s2s_records:
        print("⚠ No s2s data, skipping graph 11")
        return
    # Only successful probes
    by_ts = defaultdict(lambda: {"connect": [], "queueing": []})
    for rec in s2s_records:
        code = rec.get("code")
        if code is not None and int(code) != 200:
            continue
        connect = rec.get("connect")
        ttfb    = rec.get("ttfb")
        ts      = rec.get("timestamp", "")
        if connect is not None and ttfb is not None and connect >= 0:
            q = ttfb - connect
            if q >= 0:
                by_ts[ts]["connect"].append(connect)
                by_ts[ts]["queueing"].append(q)
    if not by_ts:
        print("⚠ No connect/ttfb data for graph 11")
        return
    sorted_ts = sorted(by_ts)
    mean_connect  = [np.mean(by_ts[ts]["connect"])  for ts in sorted_ts]
    mean_queueing = [np.mean(by_ts[ts]["queueing"]) for ts in sorted_ts]
    x = range(len(sorted_ts))

    title = "11. Decomposition: network RTT vs server queueing delay over time"
    title += " (load generator)" if from_loadgen_only else " (client prober → service)"

    fig, ax = plt.subplots(figsize=(14, 6))
    ax.stackplot(x, mean_connect, mean_queueing,
                 labels=["Network RTT (connect, includes DNS)",
                         "Server queueing delay (ttfb − connect)"],
                 colors=["#4393c3", "#d6604d"], alpha=0.85)
    ax.set_xlabel("Probe snapshot (time order)", fontsize=12)
    ax.set_ylabel("Latency (ms)", fontsize=12)
    ax.set_title(title + "\n(Note: 'connect' time includes CoreDNS resolution — "
                 "pure TCP RTT is sub-ms; queueing dominates under load)",
                 fontsize=12, fontweight="bold")
    ax.legend(loc="upper left", fontsize=10)
    ax.grid(True, alpha=0.3, axis="y")
    plt.tight_layout()
    _save(fig, output_dir, "11_queueing_vs_rtt.png")


# ---------------------------------------------------------------------------
# Graph 11b – Network RTT time-series + CDF (bimodal split)
# ---------------------------------------------------------------------------

def plot_network_rtt_only(s2s_records, output_dir, from_loadgen_only=False):
    if not s2s_records:
        print("⚠ No s2s data, skipping graph 11b")
        return
    by_ts     = defaultdict(list)
    all_conns = []
    for rec in s2s_records:
        code = rec.get("code")
        if code is not None and int(code) != 200:
            continue
        c  = rec.get("connect")
        ts = rec.get("timestamp", "")
        if c is not None and c >= 0 and ts:
            by_ts[ts].append(c)
            all_conns.append(c)
    if not by_ts:
        print("⚠ No connect data for graph 11b")
        return

    sorted_ts    = sorted(by_ts)
    mean_connect = [np.mean(by_ts[ts]) for ts in sorted_ts]
    x            = range(len(sorted_ts))

    title = "11b. Connection time: time-series (left) and CDF (right)"
    title += " (load generator)" if from_loadgen_only else " (client prober → service)"

    fig, (ax_ts, ax_cdf) = plt.subplots(1, 2, figsize=(16, 5),
                                         gridspec_kw={"width_ratios": [2, 1]})

    # Time-series
    ax_ts.fill_between(x, mean_connect, alpha=0.4, color="#4393c3")
    ax_ts.plot(x, mean_connect, color="#2166ac", linewidth=2,
               label="Mean connect time (includes DNS)")
    ax_ts.set_xlabel("Probe snapshot (time order)", fontsize=12)
    ax_ts.set_ylabel("Connect time (ms)", fontsize=12)
    ax_ts.set_title("Over time", fontsize=11)
    ax_ts.legend(fontsize=9)
    ax_ts.grid(True, alpha=0.3, axis="y")
    ax_ts.set_ylim(0, None)

    # CDF with bimodal annotation
    if all_conns:
        sv = np.sort(all_conns)
        ax_cdf.plot(sv, np.arange(1, len(sv) + 1) / len(sv),
                    color="#2166ac", linewidth=2.5)
        pct_fast = sum(1 for v in all_conns if v < 5) / len(all_conns) * 100
        pct_slow = 100 - pct_fast
        ax_cdf.axvline(5, color="orange", linestyle="--", linewidth=1.5, alpha=0.7,
                       label="5 ms threshold")
        ax_cdf.text(0.5, pct_fast / 100 * 0.9,
                    f"< 5 ms\n{pct_fast:.0f}%\n(cached DNS\nor same-node)",
                    fontsize=8, color="#1a5276",
                    transform=ax_cdf.get_xaxis_transform(), ha="left", va="top")
        ax_cdf.text(6, 0.1, f"> 5 ms\n{pct_slow:.0f}%\n(DNS lookup\nunder load)",
                    fontsize=8, color="#922b21")
        ax_cdf.set_xlabel("Connect time (ms)", fontsize=12)
        ax_cdf.set_ylabel("CDF", fontsize=12)
        ax_cdf.set_title("CDF — bimodal split", fontsize=11)
        ax_cdf.set_ylim(0, 1.05)
        ax_cdf.legend(fontsize=9)
        ax_cdf.grid(True, alpha=0.3)

    fig.suptitle(title + "\n(Bimodal: fast mode = cached/same-node; slow mode = CoreDNS "
                 "resolution under load — not pure TCP RTT)",
                 fontsize=12, fontweight="bold")
    plt.tight_layout()
    _save(fig, output_dir, "11b_network_rtt_only.png")


# ---------------------------------------------------------------------------
# NEW Graph 12 – Connection-time CDF from fortio ConnectionStats
# ---------------------------------------------------------------------------

def plot_connect_time_cdf(bursts, output_dir):
    """CDF of TCP connection establishment time (from fortio ConnectionStats).
    Reveals the bimodal distribution: fast same-node/cached-DNS vs slow DNS-lookup mode.
    """
    all_times = []
    for b in bursts:
        all_times.extend(b.get("conn_times_ms", []))
    if not all_times:
        # Fall back: use conn_p50 / conn_p95 markers if raw times not available
        print("⚠ No ConnectionStats data for graph 12 (using marker approach)")
        fig, ax = plt.subplots(figsize=(8, 5))
        vals = [(b["conn_p50_ms"], b["conn_p95_ms"]) for b in bursts
                if b.get("conn_p50_ms") and b.get("conn_p95_ms")]
        if not vals:
            plt.close(fig)
            return
        p50s = [v[0] for v in vals]
        p95s = [v[1] for v in vals]
        ax.scatter(range(len(p50s)), p50s, label="conn p50 (ms)", s=40, color="#2166ac")
        ax.scatter(range(len(p95s)), p95s, label="conn p95 (ms)", s=40, color="#d6604d", marker="s")
        ax.set_xlabel("Burst index", fontsize=12)
        ax.set_ylabel("Connection time (ms)", fontsize=12)
        ax.set_title("12. Connection time p50/p95 per burst (bimodal: fast vs slow DNS)",
                     fontsize=13, fontweight="bold")
        ax.legend()
        ax.grid(True, alpha=0.3)
        plt.tight_layout()
        _save(fig, output_dir, "12_connect_time_cdf.png")
        return

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 5))

    # Histogram
    bins = np.logspace(np.log10(max(min(all_times), 0.01)), np.log10(max(all_times) + 1), 60)
    ax1.hist(all_times, bins=bins, color="#4393c3", alpha=0.8, edgecolor="white", linewidth=0.3)
    ax1.set_xscale("log")
    ax1.set_xlabel("Connection time (ms, log scale)", fontsize=12)
    ax1.set_ylabel("Count", fontsize=12)
    ax1.set_title("Distribution (log-scale X reveals bimodal split)", fontsize=11)
    ax1.axvline(5, color="orange", linestyle="--", linewidth=1.5,
                label="5 ms threshold", alpha=0.8)
    fast = sum(1 for v in all_times if v < 5)
    slow = len(all_times) - fast
    ax1.text(0.05, 0.92, f"< 5 ms:  {fast} ({fast/len(all_times)*100:.0f}%)\n"
             f"≥ 5 ms:  {slow} ({slow/len(all_times)*100:.0f}%)",
             transform=ax1.transAxes, fontsize=9, va="top",
             bbox=dict(boxstyle="round", fc="white", alpha=0.7))
    ax1.legend(fontsize=9)
    ax1.grid(True, alpha=0.3, axis="y")

    # CDF
    sv = np.sort(all_times)
    ax2.plot(sv, np.arange(1, len(sv) + 1) / len(sv), color="#2166ac", linewidth=2.5)
    ax2.axvline(5, color="orange", linestyle="--", linewidth=1.5, alpha=0.8)
    pct_fast = fast / len(all_times)
    ax2.annotate(f"← {pct_fast*100:.0f}%\n  fast\n  (< 5 ms)",
                 xy=(5, pct_fast), xytext=(8, pct_fast - 0.1),
                 arrowprops=dict(arrowstyle="->", color="#c0392b"), fontsize=9, color="#c0392b")
    ax2.set_xlabel("Connection time (ms)", fontsize=12)
    ax2.set_ylabel("CDF", fontsize=12)
    ax2.set_title("CDF", fontsize=11)
    ax2.set_ylim(0, 1.05)
    ax2.grid(True, alpha=0.3)

    fig.suptitle("12. Connection-time distribution (all fortio connections)\n"
                 "Bimodal: fast mode = cached DNS / same-node path; "
                 "slow mode = live CoreDNS resolution under load",
                 fontsize=13, fontweight="bold")
    plt.tight_layout()
    _save(fig, output_dir, "12_connect_time_cdf.png")


# ---------------------------------------------------------------------------
# NEW Graph 13 – HPA replica count + per-endpoint latency dual-axis timeline
# ---------------------------------------------------------------------------

def plot_hpa_latency_timeline(bursts, latency_replicas_rows, output_dir):
    """Dual-axis: per-endpoint p95 latency (left) and HPA total replicas (right)
    over burst index. Marks when HPA reached its ceiling.
    """
    if not bursts:
        return

    by_ep = defaultdict(dict)
    for b in bursts:
        by_ep[b["endpoint"]][b["index"]] = b["p95"] * 1000

    endpoints = [e for e in ENDPOINT_ORDER if e in by_ep]
    if not endpoints:
        endpoints = sorted(by_ep.keys())
    all_idx = sorted({b["index"] for b in bursts})

    # Total replicas per HPA snapshot row
    hpa_total = []
    for row in latency_replicas_rows:
        cur = sum(int(v) for k, v in row.items()
                  if k.endswith("_current") and v and v.isdigit())
        hpa_total.append(cur)
    # Find when HPA stabilized (first time total replicas reach max)
    hpa_ceil_idx = None
    if hpa_total:
        max_rep = max(hpa_total)
        for i, v in enumerate(hpa_total):
            if v >= max_rep:
                hpa_ceil_idx = i
                break

    fig, ax1 = plt.subplots(figsize=(14, 6))
    ax2 = ax1.twinx()

    # Latency lines
    for ep in endpoints:
        idx_map = by_ep[ep]
        idx_list = sorted(idx_map)
        vals = [idx_map[i] for i in idx_list]
        ax1.plot(idx_list, vals, "o-", color=ENDPOINT_COLORS.get(ep, "#444"),
                 linewidth=2, markersize=5, label=f"/{ep} p95")

    # HPA replica bars on right axis
    if hpa_total:
        hpa_x = range(len(hpa_total))
        ax2.bar(hpa_x, hpa_total, color="#aaaaaa", alpha=0.3, width=0.9, zorder=0,
                label="Total replicas (HPA)")
        ax2.set_ylabel("Total running replicas", fontsize=11, color="#888")
        ax2.tick_params(axis="y", colors="#888")
        if hpa_ceil_idx is not None:
            ax2.axvline(hpa_ceil_idx, color="#e65100", linewidth=1.5,
                        linestyle=":", alpha=0.8)
            ax2.text(hpa_ceil_idx + 0.2, max(hpa_total) * 0.95,
                     f"HPA ceiling\n({max_rep} replicas)", fontsize=8, color="#e65100")

    ax1.set_xlabel("Burst / snapshot index", fontsize=12)
    ax1.set_ylabel("p95 latency (ms)", fontsize=12)
    ax1.set_title("13. HPA scaling vs end-to-end latency over time\n"
                  "(Grey bars = total running replicas; coloured lines = p95 per endpoint; "
                  "orange dotted = HPA ceiling reached)",
                  fontsize=13, fontweight="bold")
    lines1, labels1 = ax1.get_legend_handles_labels()
    lines2, labels2 = ax2.get_legend_handles_labels()
    ax1.legend(lines1 + lines2, labels1 + labels2, loc="upper right", fontsize=10)
    ax1.grid(True, alpha=0.3, zorder=2)
    ax1.set_zorder(ax2.get_zorder() + 1)
    ax1.patch.set_visible(False)
    plt.tight_layout()
    _save(fig, output_dir, "13_hpa_latency_timeline.png")


# ---------------------------------------------------------------------------
# NEW Graph 14 – Per-endpoint latency boxplot comparison
# ---------------------------------------------------------------------------

def plot_per_endpoint_latency(bursts, output_dir):
    """Grouped boxplot comparing cart / home / product latency side-by-side.
    Shows that home is consistently worse due to deeper service call chain.
    """
    by_ep = defaultdict(list)
    for b in bursts:
        by_ep[b["endpoint"]].append(b)

    endpoints = [e for e in ENDPOINT_ORDER if e in by_ep]
    if not endpoints:
        endpoints = sorted(by_ep.keys())
    if len(endpoints) < 2:
        print("⚠ Only one endpoint found, skipping graph 14")
        return

    percentile_keys = ["p50", "p95", "p99"]
    pct_labels      = ["p50", "p95", "p99"]
    n_pct = len(percentile_keys)
    n_ep  = len(endpoints)

    fig, ax = plt.subplots(figsize=(4 * n_pct, 6))

    width  = 0.8 / n_ep
    x_base = np.arange(n_pct)

    for k, ep in enumerate(endpoints):
        ep_bursts = by_ep[ep]
        c = ENDPOINT_COLORS.get(ep, "#666")
        offset = (k - (n_ep - 1) / 2) * width
        positions = x_base + offset
        data = [[b[pk] * 1000 for b in ep_bursts] for pk in percentile_keys]
        bp = ax.boxplot(data, positions=positions, widths=width * 0.85,
                        patch_artist=True, showmeans=True,
                        medianprops=dict(color="black", linewidth=2),
                        meanprops=dict(marker="D", markerfacecolor=c, markersize=5),
                        whiskerprops=dict(color=c, alpha=0.8),
                        capprops=dict(color=c),
                        boxprops=dict(facecolor=c, alpha=0.45))
        # Invisible scatter for legend
        ax.scatter([], [], color=c, s=50, label=f"/{ep}", alpha=0.8)

    ax.set_xticks(x_base)
    ax.set_xticklabels(pct_labels, fontsize=12)
    ax.set_xlabel("Latency percentile", fontsize=12)
    ax.set_ylabel("Latency (ms)", fontsize=12)
    ax.set_title("14. Per-endpoint latency comparison: /cart vs /home vs /product\n"
                 "(Home is consistently worst — it triggers more downstream service calls "
                 "including adservice + productcatalogservice + recommendationservice)",
                 fontsize=13, fontweight="bold")
    ax.legend(loc="upper left", fontsize=11)
    ax.grid(True, alpha=0.3, axis="y")
    plt.tight_layout()
    _save(fig, output_dir, "14_per_endpoint_latency.png")


# ---------------------------------------------------------------------------
# Summary stats
# ---------------------------------------------------------------------------

def generate_summary_stats(bursts, snapshots, output_dir):
    output_path = os.path.join(output_dir, "summary_stats.txt")
    with open(output_path, 'w') as f:
        f.write("Baseline Test Summary Statistics\n")
        f.write("=" * 60 + "\n\n")
        f.write("LATENCY METRICS:\n")
        f.write("-" * 40 + "\n")
        p50_vals  = [b["p50"]  * 1000 for b in bursts]
        p95_vals  = [b["p95"]  * 1000 for b in bursts]
        p99_vals  = [b["p99"]  * 1000 for b in bursts]
        p999_vals = [b["p999"] * 1000 for b in bursts]
        for label, vals in [("p50", p50_vals), ("p95", p95_vals),
                             ("p99", p99_vals), ("p999", p999_vals)]:
            f.write(f"{label}:  mean={np.mean(vals):.2f}ms, "
                    f"median={np.median(vals):.2f}ms, "
                    f"min={np.min(vals):.2f}ms, max={np.max(vals):.2f}ms\n")
        f.write("\n")
        f.write("LATENCY BY ENDPOINT:\n")
        f.write("-" * 40 + "\n")
        by_ep = defaultdict(list)
        for b in bursts:
            by_ep[b["endpoint"]].append(b)
        for ep in sorted(by_ep.keys()):
            ep_p95 = [b["p95"] * 1000 for b in by_ep[ep]]
            f.write(f"  {ep}: p95 median={np.median(ep_p95):.1f}ms "
                    f"mean={np.mean(ep_p95):.1f}ms "
                    f"max={np.max(ep_p95):.1f}ms\n")
        f.write("\n")
        f.write("QPS METRICS:\n")
        f.write("-" * 40 + "\n")
        qps_vals = [b["actual_qps"] for b in bursts]
        f.write(f"Actual QPS: mean={np.mean(qps_vals):.2f}, "
                f"median={np.median(qps_vals):.2f}, "
                f"min={np.min(qps_vals):.2f}, max={np.max(qps_vals):.2f}\n")
        f.write(f"Total bursts: {len(bursts)}\n")
        f.write(f"Total requests: {sum(b['count'] for b in bursts)}\n\n")
        if snapshots:
            f.write("POD PLACEMENT METRICS:\n")
            f.write("-" * 40 + "\n")
            f.write(f"Total snapshots: {len(snapshots)}\n")
            all_nodes = set()
            for snap in snapshots:
                all_nodes.update(snap["node_counts"].keys())
            f.write(f"Nodes: {', '.join(sorted(all_nodes))}\n")
            for node in sorted(all_nodes):
                counts = [snap["node_counts"].get(node, 0) for snap in snapshots]
                f.write(f"  {node}: mean={np.mean(counts):.1f} pods, "
                        f"min={np.min(counts)}, max={np.max(counts)}\n")
    print(f"✓ Generated: {output_path}")


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Generate visualization graphs from baseline test data"
    )
    parser.add_argument("data_dir", nargs="?",
                        help="Path to run data directory (defaults to latest under ./data)")
    parser.add_argument("-o", "--output",
                        help="Output directory for graphs (default: <data_dir>/graphs)")
    args = parser.parse_args()

    if args.data_dir:
        data_dir = args.data_dir
    else:
        script_dir = Path(__file__).parent
        data_base = script_dir / "data"
        if not data_base.exists():
            print(f"Error: No data directory at {data_base}")
            sys.exit(1)
        run_dirs = sorted([d for d in data_base.iterdir() if d.is_dir()], reverse=True)
        if not run_dirs:
            print(f"Error: No run directories under {data_base}")
            sys.exit(1)
        data_dir = str(run_dirs[0])
        print(f"Using latest run: {os.path.basename(data_dir)}")

    if not os.path.exists(data_dir):
        print(f"Error: Data directory not found: {data_dir}")
        sys.exit(1)

    output_dir = args.output or os.path.join(data_dir, "graphs")
    os.makedirs(output_dir, exist_ok=True)
    print(f"\nGenerating graphs from: {data_dir}")
    print(f"Output directory:       {output_dir}\n")

    print("Loading data...")
    bursts = load_burst_data(data_dir)
    if not bursts:
        print("Error: No burst data found")
        sys.exit(1)
    print(f"  Loaded {len(bursts)} burst files")

    bursts_config = load_bursts_jsonl(data_dir)
    if bursts_config:
        print(f"  Loaded {len(bursts_config)} configured-burst rows")

    snapshots = load_pod_placement_data(data_dir)
    print(f"  {'Loaded ' + str(len(snapshots)) + ' pod snapshots' if snapshots else 'No pod placement data'}")

    placement        = load_service_placement(data_dir)
    s2s_records      = load_s2s_data(data_dir)
    service_to_nodes = load_service_endpoint_nodes(data_dir)
    latency_rows     = load_latency_vs_replicas(data_dir)

    if s2s_records:
        print(f"  Loaded {len(s2s_records)} s2s probe records")
    else:
        print("  No s2s probe data (graphs 07–11 skipped or partially skipped)")

    LOADGEN = "fortio-loadgen"
    s2s_boutique   = [r for r in s2s_records if (r.get("source_pod") or "").strip() != LOADGEN]
    s2s_for_net    = s2s_boutique if s2s_boutique else s2s_records
    from_lg_only   = bool(s2s_records) and not s2s_boutique

    def _plot(name, func, *a, **kw):
        try:
            func(*a, **kw)
        except Exception as e:
            print(f"  ⚠ {name}: {e}")

    print("\nGenerating graphs 01–06 (load / latency / scaling / placement)...")
    _plot("01", plot_qps_comparison,       bursts, output_dir, bursts_config)
    _plot("02", plot_latency_percentiles,  bursts, output_dir)
    _plot("03", plot_latency_vs_qps,       bursts, output_dir)
    if snapshots:
        _plot("04", plot_pod_distribution, snapshots, output_dir)
    if placement:
        _plot("05", plot_service_placement, placement, output_dir)
    _plot("06", plot_latency_distribution, bursts, output_dir)
    generate_summary_stats(bursts, snapshots, output_dir)

    print("\nGenerating graphs 07–11 (network analysis)...")
    _plot("07", plot_cross_node_ratio,          s2s_for_net, service_to_nodes, output_dir, from_loadgen_only=from_lg_only)
    _plot("08", plot_same_vs_cross_node_cdf,    s2s_for_net, service_to_nodes, output_dir, from_loadgen_only=from_lg_only)
    _plot("09", plot_p95_vs_replicas,           latency_rows, output_dir)
    _plot("09b", plot_p95_vs_node_count,        latency_rows, output_dir)
    _plot("10", plot_node_pair_heatmap,         s2s_for_net, output_dir, from_loadgen_only=from_lg_only)
    _plot("10b", plot_latency_to_service_by_node, s2s_for_net, output_dir, from_loadgen_only=from_lg_only)
    _plot("11", plot_queueing_vs_rtt,           s2s_for_net, output_dir, from_loadgen_only=from_lg_only)
    _plot("11b", plot_network_rtt_only,         s2s_for_net, output_dir, from_loadgen_only=from_lg_only)

    print("\nGenerating new graphs 12–14...")
    _plot("12", plot_connect_time_cdf,     bursts, output_dir)
    _plot("13", plot_hpa_latency_timeline, bursts, latency_rows, output_dir)
    _plot("14", plot_per_endpoint_latency, bursts, output_dir)

    # Update README
    readme = os.path.join(output_dir, "README.txt")
    with open(readme, "w") as f:
        f.write("Experiment graphs — view in story order:\n\n")
        f.write("  01_qps_comparison.png             – Actual QPS per burst, coloured by endpoint (+ configured QPS line)\n")
        f.write("  02_latency_percentiles.png         – p50/p95/p99 per endpoint over time (warm-up phase annotated)\n")
        f.write("  03_latency_vs_qps.png              – Latency vs QPS scatter, warm-up phase vs steady-state\n")
        f.write("  04_pod_distribution.png            – Pod count per node over time + imbalance ratio\n")
        f.write("  05_service_placement_by_node.png   – Service placement heatmap + call graph co-location overlay\n")
        f.write("  06_latency_distribution.png        – Latency boxplots split by endpoint (cart/home/product)\n")
        f.write("  13_hpa_latency_timeline.png        – Dual-axis: HPA replica count + per-endpoint p95 over time\n")
        f.write("  14_per_endpoint_latency.png        – Grouped boxplot comparing /cart /home /product latency\n\n")
        f.write("  Network graphs (require s2s probe data):\n")
        f.write("  07_cross_node_ratio.png            – % of calls that crossed a node per service pair\n")
        f.write("  08_same_vs_cross_node_cdf.png      – Latency CDF: same-node vs cross-node calls\n")
        f.write("  09_p95_vs_replicas.png             – p95 latency vs total running replicas\n")
        f.write("  09b_p95_vs_node_count.png          – p95 latency vs pod spread across nodes\n")
        f.write("  10_node_pair_latency_heatmap.png   – p95 heatmap: source node × target service\n")
        f.write("  10b_latency_to_service_by_node.png – p95 to each service by node (gRPC panels annotated)\n")
        f.write("  11_queueing_vs_rtt.png             – Decomposition: network RTT vs server queueing delay\n")
        f.write("  11b_network_rtt_only.png           – Connect-time time-series + CDF (bimodal split)\n")
        f.write("  12_connect_time_cdf.png            – Connection-time distribution: fast (<5ms) vs slow (DNS)\n\n")
        f.write("  summary_stats.txt                  – Numeric summary\n")
    print(f"✓ Generated: {readme}")
    print(f"\n✓ All graphs written to: {output_dir}")


if __name__ == "__main__":
    main()
