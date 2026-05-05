#!/usr/bin/env python3
"""plot_results.py -- generate comparison plots from a results/<timestamp>/ run.

Reads per-scenario stat files and produces 6 PNGs in <results-dir>/plots/:
  cv_across_scenarios.png       -- horizontal bar chart of CV across all scenarios
  per_pod_connections.png       -- grouped bar chart, fortio vs h2dial 02/03
  p99_comparison.png            -- p99 latency across scenarios
  goaway_rate.png               -- counter values (max_duration_reached, max_requests_reached) by scenario
  he_timeseries.png             -- CV vs upstream p95/p99 time series for scenario 02
  filter_chain_overhead.png     -- p99 comparison between scenario 2 and 11

Usage:
    plot_results.py <results-dir>
"""
from __future__ import annotations

import csv
import os
import re
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


def read_cv_p99(scen_dir: Path) -> tuple[float, float]:
    """Read CV and p99 from <scen>/cv.txt."""
    cv = 0.0
    p99 = 0.0
    cv_file = scen_dir / "cv.txt"
    if not cv_file.exists():
        return cv, p99
    for line in cv_file.read_text().splitlines():
        m = re.search(r"CV.*= ([0-9.]+)", line)
        if m:
            cv = float(m.group(1))
        m = re.search(r"p99 latency = ([0-9.]+)s", line)
        if m:
            p99 = float(m.group(1))
    return cv, p99


def read_per_pod(file_path: Path) -> dict[str, int]:
    """Read 'pod count' lines into a dict."""
    out: dict[str, int] = {}
    if not file_path.exists():
        return out
    for line in file_path.read_text().splitlines():
        parts = line.split()
        if len(parts) >= 2:
            try:
                out[parts[0]] = int(parts[1])
            except ValueError:
                pass
    return out


def sum_per_pod(file_path: Path) -> int:
    return sum(read_per_pod(file_path).values())


def plot_cv_across_scenarios(results: Path, scenarios: list[Path]) -> None:
    names: list[str] = []
    cvs: list[float] = []
    for d in scenarios:
        cv, _ = read_cv_p99(d)
        names.append(d.name)
        cvs.append(cv)
    fig, ax = plt.subplots(figsize=(10, max(4, 0.5 * len(names))))
    colors = ["#4ea6ff" if "fortio" in n else "#1f77b4" for n in names]
    ax.barh(names, cvs, color=colors)
    ax.set_xlabel("CV(downstream_cx_http2_total) across IGW pods")
    ax.set_title(
        "Per-pod connection-distribution variance across scenarios\n"
        "(higher = more concentrated; fortio scenarios in lighter blue)"
    )
    ax.axvline(0.5, color="gray", linestyle="--", alpha=0.4, label="reference: 0.5 = 1 idle pod of 3")
    ax.legend(loc="lower right")
    ax.invert_yaxis()
    plt.tight_layout()
    out = results / "plots" / "cv_across_scenarios.png"
    plt.savefig(out, dpi=120)
    plt.close()
    print(f"  wrote {out}")


def plot_per_pod_connections(results: Path) -> None:
    """Compare per-pod connection distribution: fortio vs h2dial for s2 and s3."""
    scenarios = [
        ("02-trigger", "h2dial cap=65536"),
        ("02-fortio", "fortio cap=65536"),
        ("03-mcs-cap", "h2dial cap=128"),
        ("03-fortio", "fortio cap=128"),
    ]
    available = [(name, label, results / name) for name, label in scenarios if (results / name).exists()]
    if not available:
        print("  skipping per_pod_connections: no relevant scenarios found")
        return
    pods: list[str] = []
    for _, _, d in available:
        for p in read_per_pod(d / "cx_http2_total_per_pod.txt"):
            if p not in pods:
                pods.append(p)
    pods.sort()

    fig, ax = plt.subplots(figsize=(10, 5))
    x = range(len(available))
    width = 0.8 / max(1, len(pods))
    for i, pod in enumerate(pods):
        vals = [read_per_pod(d / "cx_http2_total_per_pod.txt").get(pod, 0) for _, _, d in available]
        ax.bar([xi + i * width for xi in x], vals, width, label=pod[-12:])
    ax.set_xticks([xi + (len(pods) - 1) * width / 2 for xi in x])
    ax.set_xticklabels([label for _, label, _ in available], rotation=15)
    ax.set_ylabel("HTTP/2 connections accepted (cumulative)")
    ax.set_title(
        "Per-pod TCP connection distribution: fortio vs h2dial under the same cap\n"
        "Equal bars across pods = healthy distribution; uneven = concentration"
    )
    ax.legend(loc="upper right", fontsize=8)
    plt.tight_layout()
    out = results / "plots" / "per_pod_connections.png"
    plt.savefig(out, dpi=120)
    plt.close()
    print(f"  wrote {out}")


def plot_p99_comparison(results: Path, scenarios: list[Path]) -> None:
    names: list[str] = []
    p99s: list[float] = []
    for d in scenarios:
        _, p99 = read_cv_p99(d)
        if p99 > 0:
            names.append(d.name)
            p99s.append(p99 * 1000)  # to ms
    if not names:
        print("  skipping p99_comparison: no p99 values parsed")
        return
    fig, ax = plt.subplots(figsize=(10, max(4, 0.5 * len(names))))
    colors = ["#fb6f6f" if "fortio" in n else "#d62728" for n in names]
    ax.barh(names, p99s, color=colors)
    ax.set_xlabel("p99 latency (ms)")
    ax.set_title("p99 latency by scenario (lower is better)")
    ax.invert_yaxis()
    plt.tight_layout()
    out = results / "plots" / "p99_comparison.png"
    plt.savefig(out, dpi=120)
    plt.close()
    print(f"  wrote {out}")


def plot_goaway_rate(results: Path) -> None:
    scenarios = ["02-trigger", "03-mcs-cap", "04-mrpc", "05-windows"]
    available = [(s, results / s) for s in scenarios if (results / s).exists()]
    if not available:
        print("  skipping goaway_rate: no scenarios found")
        return
    duration_vals = [sum_per_pod(d / "cx_max_duration_reached.txt") for _, d in available]
    requests_vals = [sum_per_pod(d / "cx_max_requests_reached.txt") for _, d in available]
    fig, ax = plt.subplots(figsize=(10, 5))
    x = range(len(available))
    width = 0.4
    ax.bar([xi - width / 2 for xi in x], duration_vals, width, label="max_duration_reached", color="#9467bd")
    ax.bar([xi + width / 2 for xi in x], requests_vals, width, label="max_requests_reached", color="#2ca02c")
    ax.set_xticks(list(x))
    ax.set_xticklabels([s for s, _ in available], rotation=15)
    ax.set_ylabel("count over 60s measure window (sum across pods)")
    ax.set_title("GOAWAY firings per scenario (H-C: scenario 4 should have non-zero max_requests_reached)")
    ax.legend()
    plt.tight_layout()
    out = results / "plots" / "goaway_rate.png"
    plt.savefig(out, dpi=120)
    plt.close()
    print(f"  wrote {out}")


def plot_he_timeseries(results: Path) -> None:
    csv_path = results / "02-trigger" / "timeseries.csv"
    if not csv_path.exists():
        print("  skipping he_timeseries: no scenario 02-trigger/timeseries.csv")
        return
    rows = list(csv.DictReader(csv_path.open()))
    if not rows:
        print("  skipping he_timeseries: csv empty")
        return
    t0 = int(rows[0]["timestamp"])
    secs = [int(r["timestamp"]) - t0 for r in rows]
    cv = [float(r["cv"]) for r in rows]
    p99 = [float(r["upstream_p99"]) for r in rows]
    fig, ax1 = plt.subplots(figsize=(10, 5))
    ax2 = ax1.twinx()
    ax1.plot(secs, cv, "o-", color="#1f77b4", label="CV across pods")
    ax2.plot(secs, p99, "s--", color="#d62728", label="upstream p99 (ms)")
    ax1.set_xlabel("seconds since measure window start")
    ax1.set_ylabel("CV (stddev/mean)", color="#1f77b4")
    ax2.set_ylabel("upstream p99 latency (ms)", color="#d62728")
    ax1.set_title(
        "H-E (CV-as-leading-indicator) for scenario 02-trigger\n"
        "Brief claim: CV rises BEFORE p99 jumps. Inspect crossover timing."
    )
    fig.legend(loc="upper left", bbox_to_anchor=(0.1, 0.92))
    plt.tight_layout()
    out = results / "plots" / "he_timeseries.png"
    plt.savefig(out, dpi=120)
    plt.close()
    print(f"  wrote {out}")


def plot_filter_chain_overhead(results: Path) -> None:
    s2 = results / "02-trigger"
    s11 = results / "11-realistic-filters"
    if not (s2.exists() and s11.exists()):
        print("  skipping filter_chain_overhead: need 02-trigger and 11-realistic-filters")
        return
    _, p99_bare = read_cv_p99(s2)
    _, p99_full = read_cv_p99(s11)
    fig, ax = plt.subplots(figsize=(7, 5))
    bars = ax.bar(["02-trigger\n(bare HCM)", "11-realistic-filters\n(NR access log + max_concurrent_streams)"],
                  [p99_bare * 1000, p99_full * 1000],
                  color=["#1f77b4", "#9467bd"])
    ax.set_ylabel("p99 latency (ms)")
    ax.set_title("Filter chain overhead (realistic vs bare)")
    for bar, val in zip(bars, [p99_bare * 1000, p99_full * 1000]):
        ax.text(bar.get_x() + bar.get_width() / 2, val + 0.05,
                f"{val:.2f} ms", ha="center")
    plt.tight_layout()
    out = results / "plots" / "filter_chain_overhead.png"
    plt.savefig(out, dpi=120)
    plt.close()
    print(f"  wrote {out}")


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    results = Path(sys.argv[1]).resolve()
    if not results.is_dir():
        print(f"not a directory: {results}", file=sys.stderr)
        return 1
    (results / "plots").mkdir(exist_ok=True)
    scenario_dirs = sorted(p for p in results.iterdir() if p.is_dir() and re.match(r"\d{2}", p.name))
    if not scenario_dirs:
        print(f"no scenario dirs in {results}", file=sys.stderr)
        return 1
    print(f"plotting {len(scenario_dirs)} scenarios from {results}")
    plot_cv_across_scenarios(results, scenario_dirs)
    plot_per_pod_connections(results)
    plot_p99_comparison(results, scenario_dirs)
    plot_goaway_rate(results)
    plot_he_timeseries(results)
    plot_filter_chain_overhead(results)
    print("done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
