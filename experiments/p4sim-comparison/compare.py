#!/usr/bin/env python3
"""Compares the delay distributions P4-Days and P4sim produce for the same run.

Two averages that happen to agree say little; a median and a tail that agree
say the two are doing the same thing. Slowdown is reported as well as raw
delay, because the link rates and per-hop costs are not identical between the
simulators and slowdown normalises that away.
"""
import csv
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load(path, time_col, flow_col, delay_col):
    rows = []
    with open(path) as f:
        for r in csv.DictReader(f):
            rows.append((int(r[flow_col]), float(r[delay_col])))
    return rows


def pct(values, p):
    if not values:
        return float("nan")
    s = sorted(values)
    if len(s) == 1:
        return s[0]
    k = (len(s) - 1) * p / 100.0
    lo, hi = int(k), min(int(k) + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)


def summarise(rows):
    per_flow = {}
    for flow, delay in rows:
        per_flow.setdefault(flow, []).append(delay)
    return per_flow


def main():
    days_path = HERE.parent.parent / "days/logs/m4/days/arrivals.csv"
    p4sim_path = HERE / "p4sim_flows.csv.arrivals.csv"
    for p in (days_path, p4sim_path):
        if not p.exists():
            print(f"missing {p}", file=sys.stderr)
            return 1

    days = summarise(load(days_path, "time", "flow_id", "one_way_delay"))
    p4sim = summarise(load(p4sim_path, "time", "flow_id", "one_way_delay"))

    flows = sorted(set(days) | set(p4sim))

    # Aggregate first. Under saturation the two simulators break ties between
    # flows differently, so the per-flow split is not a like-for-like number;
    # how much the network as a whole carried and dropped is.
    print(f"{'side':>8} {'delivered':>10} {'per flow':>22}")
    print("-" * 42)
    for name, data in (("P4-Days", days), ("P4sim", p4sim)):
        per = "  ".join(f"{f}={len(data.get(f, []))}" for f in flows)
        print(f"{name:>8} {sum(len(v) for v in data.values()):>10} {per:>22}")
    print()
    print(f"{'flow':>8} {'side':>8} {'n':>4} "
          f"{'min(us)':>10} {'p50(us)':>10} {'p99(us)':>10} {'max(us)':>10}")
    print("-" * 66)

    stats = {}
    for flow in flows:
        for name, data in (("P4-Days", days), ("P4sim", p4sim)):
            d = [v * 1e6 for v in data.get(flow, [])]
            stats[(flow, name)] = d
            print(f"{flow:>8} {name:>8} {len(d):>4} "
                  f"{min(d):>10.3f} {pct(d,50):>10.3f} {pct(d,99):>10.3f} {max(d):>10.3f}"
                  if d else f"{flow:>8} {name:>8}    0")
        print()

    # Slowdown: each packet's delay over the ideal delay, which is the smallest
    # delay that side saw across *every* flow -- the one packet that met no
    # queue anywhere. Normalising per flow instead would divide each flow by its
    # own best case, which hides any queueing a flow suffers on every packet and
    # reports 1.0 for a fully congested run.
    ideal = {name: min((v for (f, n), d in stats.items() if n == name for v in d),
                       default=float("nan"))
             for name in ("P4-Days", "P4sim")}
    print(f"ideal (no-queueing) delay:  "
          f"P4-Days {ideal['P4-Days']:.3f} us   P4sim {ideal['P4sim']:.3f} us")
    print()
    print(f"{'flow':>8} {'side':>8} {'p50 slowdown':>14} {'p99 slowdown':>14}")
    print("-" * 48)
    verdict_ok = True
    for flow in flows:
        row = {}
        for name in ("P4-Days", "P4sim"):
            d = stats[(flow, name)]
            if not d:
                continue
            base = ideal[name]
            sd = [x / base for x in d] if base > 0 else [1.0 for _ in d]
            row[name] = (pct(sd, 50), pct(sd, 99))
            print(f"{flow:>8} {name:>8} {row[name][0]:>14.4f} {row[name][1]:>14.4f}")
        if len(row) == 2:
            for i, label in enumerate(("p50", "p99")):
                a, b = row["P4-Days"][i], row["P4sim"][i]
                diff = abs(a - b) / max(a, b, 1e-12)
                print(f"{'':>8} {label:>8} relative difference {diff*100:>8.2f} %")
        print()

    # The verdict is taken over every packet at once. Once a shared buffer
    # saturates, which flow finds it full is settled by the order two events at
    # the same instant happen to be processed in, and the two simulators order
    # them differently: Days lets the flow declared first hold the buffer, which
    # it does with the P4 switches removed as well, so this is not something the
    # integration introduces and not something either side is wrong about. What
    # the two must agree on is how much the network carried and how long it took.
    print("=" * 66)
    print("all packets pooled, flows not distinguished")
    print(f"{'side':>9} {'n':>6} {'p50':>9} {'p90':>9} {'p99':>9} {'max':>9}")
    print("-" * 66)
    pooled = {}
    for name, data in (("P4-Days", days), ("P4sim", p4sim)):
        d = [v * 1e6 for vals in data.values() for v in vals]
        if not d:
            continue
        base = min(d)
        pooled[name] = [x / base for x in d]
        print(f"{name:>9} {len(d):>6} "
              f"{pct(pooled[name],50):>9.3f} {pct(pooled[name],90):>9.3f} "
              f"{pct(pooled[name],99):>9.3f} {max(pooled[name]):>9.3f}")
    print()
    verdict_ok = len(pooled) == 2
    if verdict_ok:
        for p in (50, 90, 99):
            a, b = pct(pooled["P4-Days"], p), pct(pooled["P4sim"], p)
            diff = abs(a - b) / max(a, b, 1e-12)
            mark = "ok" if diff < 0.05 else "DIFFERS"
            if diff >= 0.05:
                verdict_ok = False
            print(f"  p{p} relative difference {diff*100:>7.2f} %  {mark}")

    print("=" * 66)
    print("slowdown distributions agree" if verdict_ok
          else "slowdown distributions differ — inspect before using in a paper")
    return 0 if verdict_ok else 1


if __name__ == "__main__":
    sys.exit(main())
