#!/usr/bin/env python3
"""
Analyze detailed network data collected during load tests.
Generates reports on pod-to-pod latencies, pod placement, and network performance.
"""

import argparse
import glob
import json
import os
import re
import sys
from collections import defaultdict
from pathlib import Path

try:
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    import numpy as np
    HAS_MATPLOTLIB = True
except ImportError:
    HAS_MATPLOTLIB = False
    print("Warning: matplotlib not found. Graphs will be skipped.")


def load_network_data(data_dir):
    """Load all network analysis data."""
    network_dir = os.path.join(data_dir, "network-analysis")
    if not os.path.exists(network_dir):
        print(f"Error: Network analysis directory not found: {network_dir}")
        return None
    
    data = {
        'pod_network': [],
        'service_endpoints': [],
        'pod_latencies': [],
        'node_network': [],
        'service_metrics': []
    }
    
    # Load pod network snapshots
    for file_path in sorted(glob.glob(os.path.join(network_dir, "pod-network-*.json"))):
        try:
            with open(file_path, 'r') as f:
                data['pod_network'].append(json.load(f))
        except Exception as e:
            print(f"Warning: Could not load {file_path}: {e}")
    
    # Load service endpoints
    for file_path in sorted(glob.glob(os.path.join(network_dir, "service-endpoints-*.json"))):
        try:
            with open(file_path, 'r') as f:
                data['service_endpoints'].append(json.load(f))
        except Exception as e:
            print(f"Warning: Could not load {file_path}: {e}")
    
    # Load pod-to-pod latencies
    for file_path in sorted(glob.glob(os.path.join(network_dir, "pod-latency-*.txt"))):
        try:
            with open(file_path, 'r') as f:
                content = f.read()
                timestamp_match = re.search(r'Timestamp: (\S+)', content)
                if timestamp_match:
                    timestamp = timestamp_match.group(1)
                    data['pod_latencies'].append({
                        'timestamp': timestamp,
                        'content': content,
                        'file': file_path
                    })
        except Exception as e:
            print(f"Warning: Could not load {file_path}: {e}")
    
    # Load node network info
    for file_path in sorted(glob.glob(os.path.join(network_dir, "node-network-*.json"))):
        try:
            with open(file_path, 'r') as f:
                data['node_network'].append(json.load(f))
        except Exception as e:
            print(f"Warning: Could not load {file_path}: {e}")
    
    return data


def analyze_pod_placement(data, output_dir):
    """Analyze pod placement patterns over time."""
    print("\n=== Pod Placement Analysis ===")
    
    output_file = os.path.join(output_dir, "pod-placement-analysis.txt")
    
    with open(output_file, 'w') as f:
        f.write("Pod Placement Analysis\n")
        f.write("=" * 60 + "\n\n")
        
        if not data['pod_network']:
            f.write("No pod network data available.\n")
            return
        
        # Track pod movements
        pod_locations = defaultdict(list)
        node_pod_counts = defaultdict(lambda: defaultdict(int))
        
        for snapshot in data['pod_network']:
            timestamp = snapshot.get('timestamp', 'unknown')
            
            for pod in snapshot.get('pods', []):
                pod_name = pod.get('name', 'unknown')
                node = pod.get('node', 'unknown')
                app = pod.get('app', 'unknown')
                
                pod_locations[pod_name].append({
                    'timestamp': timestamp,
                    'node': node,
                    'app': app,
                    'podIP': pod.get('podIP'),
                    'phase': pod.get('phase')
                })
                
                if app != 'unknown':
                    node_pod_counts[timestamp][node] += 1
        
        # Report pod movements (pods that changed nodes)
        f.write("Pod Movements:\n")
        f.write("-" * 60 + "\n")
        movements_found = False
        for pod_name, locations in pod_locations.items():
            nodes = [loc['node'] for loc in locations]
            unique_nodes = set(nodes)
            if len(unique_nodes) > 1:
                movements_found = True
                f.write(f"\n{pod_name}:\n")
                for loc in locations:
                    f.write(f"  {loc['timestamp']}: {loc['node']} ({loc['phase']})\n")
        
        if not movements_found:
            f.write("  No pod movements detected (pods remained on same nodes)\n")
        
        f.write("\n\n")
        
        # Pod distribution per node over time
        f.write("Pod Distribution Over Time:\n")
        f.write("-" * 60 + "\n")
        for timestamp in sorted(node_pod_counts.keys())[:10]:  # Show first 10 samples
            f.write(f"\n{timestamp}:\n")
            for node, count in sorted(node_pod_counts[timestamp].items()):
                f.write(f"  {node}: {count} pods\n")
        
        if len(node_pod_counts) > 10:
            f.write(f"\n... (showing first 10 of {len(node_pod_counts)} samples)\n")
        
        # Service-specific placement
        f.write("\n\nService Placement Patterns:\n")
        f.write("-" * 60 + "\n")
        
        service_nodes = defaultdict(set)
        for snapshot in data['pod_network']:
            for pod in snapshot.get('pods', []):
                app = pod.get('app')
                node = pod.get('node')
                if app and node:
                    service_nodes[app].add(node)
        
        for service, nodes in sorted(service_nodes.items()):
            f.write(f"\n{service}:\n")
            f.write(f"  Nodes used: {', '.join(sorted(nodes))}\n")
            f.write(f"  Node diversity: {len(nodes)}\n")
    
    print(f"✓ Generated: {output_file}")


def analyze_pod_latencies(data, output_dir):
    """Analyze pod-to-pod latencies."""
    print("\n=== Pod-to-Pod Latency Analysis ===")
    
    output_file = os.path.join(output_dir, "pod-latency-analysis.txt")
    
    with open(output_file, 'w') as f:
        f.write("Pod-to-Pod Latency Analysis\n")
        f.write("=" * 60 + "\n\n")
        
        if not data['pod_latencies']:
            f.write("No pod latency data available.\n")
            return
        
        f.write(f"Total latency measurements: {len(data['pod_latencies'])}\n\n")
        
        # Parse latencies from text files
        latency_data = defaultdict(list)
        
        for measurement in data['pod_latencies']:
            content = measurement['content']
            timestamp = measurement['timestamp']
            
            # Parse pod-to-service latencies
            current_pod = None
            for line in content.split('\n'):
                if line.startswith('Source:'):
                    current_pod = line.split(':')[1].strip()
                elif '->' in line and current_pod:
                    match = re.search(r'-> (\S+): (\S+)', line)
                    if match:
                        target = match.group(1)
                        latency_str = match.group(2)
                        if latency_str != 'N/A':
                            try:
                                # Parse latency (could be in various formats)
                                latency_ms = float(latency_str.replace('ms', '').replace('s', '')) * 1000
                                latency_data[f"{current_pod}->{target}"].append({
                                    'timestamp': timestamp,
                                    'latency_ms': latency_ms
                                })
                            except ValueError:
                                pass
        
        # Report average latencies per path
        f.write("Average Latencies by Communication Path:\n")
        f.write("-" * 60 + "\n")
        
        for path, measurements in sorted(latency_data.items()):
            if measurements:
                latencies = [m['latency_ms'] for m in measurements]
                f.write(f"\n{path}:\n")
                f.write(f"  Samples: {len(latencies)}\n")
                f.write(f"  Min: {min(latencies):.2f}ms\n")
                f.write(f"  Mean: {np.mean(latencies):.2f}ms\n")
                f.write(f"  Max: {max(latencies):.2f}ms\n")
                f.write(f"  Std Dev: {np.std(latencies):.2f}ms\n")
    
    print(f"✓ Generated: {output_file}")


def analyze_service_topology(data, output_dir):
    """Analyze service endpoint topology."""
    print("\n=== Service Topology Analysis ===")
    
    output_file = os.path.join(output_dir, "service-topology-analysis.txt")
    
    with open(output_file, 'w') as f:
        f.write("Service Topology Analysis\n")
        f.write("=" * 60 + "\n\n")
        
        if not data['service_endpoints']:
            f.write("No service endpoint data available.\n")
            return
        
        # Analyze latest snapshot
        latest = data['service_endpoints'][-1]
        
        f.write("Service Endpoint Distribution:\n")
        f.write("-" * 60 + "\n")
        
        for endpoint in latest.get('endpoints', []):
            service_name = endpoint.get('service', 'unknown')
            f.write(f"\n{service_name}:\n")
            
            for subset in endpoint.get('subsets', []):
                addresses = subset.get('addresses', [])
                f.write(f"  Endpoints: {len(addresses)}\n")
                
                # Group by node
                by_node = defaultdict(list)
                for addr in addresses:
                    node = addr.get('nodeName', 'unknown')
                    ip = addr.get('ip', 'unknown')
                    by_node[node].append(ip)
                
                for node, ips in sorted(by_node.items()):
                    f.write(f"    {node}: {len(ips)} endpoints\n")
                    for ip in ips:
                        f.write(f"      - {ip}\n")
    
    print(f"✓ Generated: {output_file}")


def generate_visualizations(data, output_dir):
    """Generate visualization graphs."""
    if not HAS_MATPLOTLIB:
        print("\nSkipping visualizations (matplotlib not available)")
        return
    
    print("\n=== Generating Visualizations ===")
    
    # Graph 1: Pod count per node over time
    if data['pod_network']:
        fig, ax = plt.subplots(figsize=(14, 6))
        
        node_counts = defaultdict(lambda: defaultdict(int))
        timestamps = []
        
        for idx, snapshot in enumerate(data['pod_network']):
            timestamps.append(idx)
            for pod in snapshot.get('pods', []):
                node = pod.get('node', 'unknown')
                if node != 'unknown':
                    node_counts[node][idx] += 1
        
        for node, counts in node_counts.items():
            x = sorted(counts.keys())
            y = [counts[i] for i in x]
            ax.plot(x, y, marker='o', label=node, linewidth=2, markersize=4)
        
        ax.set_xlabel('Sample Index', fontsize=12)
        ax.set_ylabel('Number of Pods', fontsize=12)
        ax.set_title('Pod Distribution Across Nodes Over Time', fontsize=14, fontweight='bold')
        ax.legend(loc='best', fontsize=10)
        ax.grid(True, alpha=0.3)
        
        plt.tight_layout()
        output_path = os.path.join(output_dir, "pod-distribution-timeline.png")
        plt.savefig(output_path, dpi=300, bbox_inches='tight')
        print(f"✓ Generated: {output_path}")
        plt.close()


def main():
    parser = argparse.ArgumentParser(
        description="Analyze detailed network data from load tests"
    )
    parser.add_argument(
        "data_dir",
        nargs="?",
        help="Path to data directory (e.g., stage1-baseline/data/20260214-191727)"
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
    
    # Create output directory
    output_dir = os.path.join(data_dir, "network-analysis")
    os.makedirs(output_dir, exist_ok=True)
    
    print(f"\n{'=' * 60}")
    print(f"Network Data Analysis")
    print(f"{'=' * 60}")
    print(f"Data directory: {data_dir}")
    print(f"Output directory: {output_dir}")
    
    # Load data
    print("\nLoading network data...")
    data = load_network_data(data_dir)
    
    if not data:
        sys.exit(1)
    
    print(f"  Pod network snapshots: {len(data['pod_network'])}")
    print(f"  Service endpoints: {len(data['service_endpoints'])}")
    print(f"  Pod latency measurements: {len(data['pod_latencies'])}")
    print(f"  Node network snapshots: {len(data['node_network'])}")
    
    # Perform analyses
    analyze_pod_placement(data, output_dir)
    analyze_pod_latencies(data, output_dir)
    analyze_service_topology(data, output_dir)
    generate_visualizations(data, output_dir)
    
    print(f"\n{'=' * 60}")
    print("Analysis complete!")
    print(f"{'=' * 60}")
    print(f"\nResults in: {output_dir}")
    print("  - pod-placement-analysis.txt")
    print("  - pod-latency-analysis.txt")
    print("  - service-topology-analysis.txt")
    if HAS_MATPLOTLIB:
        print("  - pod-distribution-timeline.png")
    print("")


if __name__ == "__main__":
    main()
