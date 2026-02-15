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
    """Load latency data from all fortio burst files."""
    loadgen_dir = os.path.join(data_dir, "loadgen")
    burst_files = sorted(glob.glob(os.path.join(loadgen_dir, "fortio-burst-*.json")))
    
    bursts = []
    for file_path in burst_files:
        with open(file_path, 'r') as f:
            data = json.load(f)
        
        # Extract percentiles
        percentiles = {p["Percentile"]: p["Value"] for p in data.get("DurationHistogram", {}).get("Percentiles", [])}
        
        burst_info = {
            "file": os.path.basename(file_path),
            "index": int(os.path.basename(file_path).replace("fortio-burst-", "").replace(".json", "")),
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
    
    return sorted(bursts, key=lambda x: x["index"])


def load_pod_placement_data(data_dir):
    """Load pod placement snapshots over time."""
    placement_dir = os.path.join(data_dir, "pod-placement")
    if not os.path.exists(placement_dir):
        return None
    
    index_file = os.path.join(placement_dir, "index.jsonl")
    if not os.path.exists(index_file):
        return None
    
    snapshots = []
    with open(index_file, 'r') as f:
        for line in f:
            entry = json.loads(line.strip())
            snapshot_file = os.path.join(placement_dir, entry["file"])
            
            if not os.path.exists(snapshot_file):
                continue
            
            with open(snapshot_file, 'r') as sf:
                snapshot_data = json.load(sf)
            
            # Count pods per node (only default namespace)
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
    
    return sorted(snapshots, key=lambda x: x["index"])


def plot_latency_percentiles(bursts, output_dir):
    """Plot latency percentiles (p50, p95, p99, p99.9) over bursts."""
    fig, ax = plt.subplots(figsize=(14, 6))
    
    indices = [b["index"] for b in bursts]
    p50 = [b["p50"] * 1000 for b in bursts]  # Convert to ms
    p95 = [b["p95"] * 1000 for b in bursts]
    p99 = [b["p99"] * 1000 for b in bursts]
    p999 = [b["p999"] * 1000 for b in bursts]
    
    ax.plot(indices, p50, 'o-', label='p50', linewidth=2, markersize=4)
    ax.plot(indices, p95, 's-', label='p95', linewidth=2, markersize=4)
    ax.plot(indices, p99, '^-', label='p99', linewidth=2, markersize=4)
    ax.plot(indices, p999, 'v-', label='p99.9', linewidth=2, markersize=4)
    
    ax.set_xlabel('Burst Index', fontsize=12)
    ax.set_ylabel('Latency (ms)', fontsize=12)
    ax.set_title('Response Latency Percentiles Across Traffic Bursts', fontsize=14, fontweight='bold')
    ax.legend(loc='best', fontsize=10)
    ax.grid(True, alpha=0.3)
    
    plt.tight_layout()
    output_path = os.path.join(output_dir, "latency_percentiles.png")
    plt.savefig(output_path, dpi=300, bbox_inches='tight')
    print(f"✓ Generated: {output_path}")
    plt.close()


def plot_qps_comparison(bursts, output_dir):
    """Plot requested vs actual QPS per burst."""
    fig, ax = plt.subplots(figsize=(14, 6))
    
    indices = [b["index"] for b in bursts]
    requested = [b["requested_qps"] for b in bursts]
    actual = [b["actual_qps"] for b in bursts]
    
    width = 0.35
    x = np.arange(len(indices))
    
    ax.bar(x - width/2, requested, width, label='Requested QPS', alpha=0.8)
    ax.bar(x + width/2, actual, width, label='Actual QPS', alpha=0.8)
    
    ax.set_xlabel('Burst Index', fontsize=12)
    ax.set_ylabel('Queries Per Second (QPS)', fontsize=12)
    ax.set_title('Requested vs Actual QPS per Burst', fontsize=14, fontweight='bold')
    ax.set_xticks(x[::2])  # Show every 2nd label to avoid crowding
    ax.set_xticklabels([str(i) for i in indices[::2]])
    ax.legend(loc='best', fontsize=10)
    ax.grid(True, alpha=0.3, axis='y')
    
    plt.tight_layout()
    output_path = os.path.join(output_dir, "qps_comparison.png")
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
    ax.set_title('Latency vs QPS Correlation', fontsize=14, fontweight='bold')
    ax.legend(loc='best', fontsize=10)
    ax.grid(True, alpha=0.3)
    
    plt.tight_layout()
    output_path = os.path.join(output_dir, "latency_vs_qps.png")
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
    
    ax.set_xlabel('Snapshot Index', fontsize=12)
    ax.set_ylabel('Number of Pods', fontsize=12)
    ax.set_title('Pod Distribution Across Nodes Over Time', fontsize=14, fontweight='bold')
    ax.legend(loc='upper left', fontsize=10, bbox_to_anchor=(1, 1))
    ax.grid(True, alpha=0.3, axis='y')
    
    plt.tight_layout()
    output_path = os.path.join(output_dir, "pod_distribution.png")
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
    ax.set_title('Latency Distribution Across All Bursts', fontsize=14, fontweight='bold')
    ax.grid(True, alpha=0.3, axis='y')
    
    plt.tight_layout()
    output_path = os.path.join(output_dir, "latency_distribution.png")
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
    
    # Generate graphs
    print("\nGenerating graphs...")
    plot_latency_percentiles(bursts, output_dir)
    plot_qps_comparison(bursts, output_dir)
    plot_latency_vs_qps(bursts, output_dir)
    plot_latency_distribution(bursts, output_dir)
    
    if snapshots:
        plot_pod_distribution(snapshots, output_dir)
    
    generate_summary_stats(bursts, snapshots, output_dir)
    
    print(f"\n✓ All graphs generated in: {output_dir}")
    print("\nGenerated files:")
    print("  - latency_percentiles.png   : p50/p95/p99/p99.9 over time")
    print("  - qps_comparison.png        : Requested vs actual QPS")
    print("  - latency_vs_qps.png        : Latency correlation with QPS")
    print("  - latency_distribution.png  : Box plot of latency distribution")
    if snapshots:
        print("  - pod_distribution.png      : Pod placement across nodes over time")
    print("  - summary_stats.txt         : Summary statistics")


if __name__ == "__main__":
    main()
