#!/usr/bin/env python3
"""Did the two simulators do the same thing?

Two checks, and they answer different questions.

**Registers** say what each pipeline did, as integers. The verification program
keeps a counter per (egress port, flow) at every switch, so a matching pair of
dumps means: switch s forwarded exactly N packets of flow f out port p, for
every s, p and f. Drops are in there implicitly -- a packet dropped on the link
between two switches is counted at the first and not at the second -- so the
difference between adjacent switches is that link's drop count, per flow. Either
the dumps are identical or they are not; there is no distribution to match.

**Per-packet delay** says whether the same packets arrived at the same time.
Registers carry no time at all, so this is the half they cannot answer. Matching
delay *distributions* is a weaker claim than it looks: two runs could deliver
every packet at a different moment and still produce the same percentiles. This
joins packet i to packet i and reports the largest disagreement.

A constant offset is expected and is not a disagreement: BMv2 charges a small
per-packet cost at a finite SwitchRate, which Days does not model, so every
packet on the ns-3 side is late by the same amount times the hop count. The
report gives the spread around the offset as well as the raw maximum.

Usage:
  verify.py --days-log <dir> --days-regs <dir> --ns3-arrivals <file> \
            --ns3-regs <dir> [--switch-offset N]

`--switch-offset` is the Days node id of ns-3 switch 0; the two number their
switches differently and the dumps are keyed by each side's own ids.
"""
import argparse
import csv
import statistics
import sys
from collections import defaultdict
from pathlib import Path


def load_registers(directory, offset=0):
    """{(switch, register, index): value}, switch ids shifted into Days' space."""
    out = {}
    for path in sorted(Path(directory).glob("registers_*.csv")):
        with open(path) as f:
            for row in csv.DictReader(f):
                key = (int(row["switch_id"]) + offset, row["register"], int(row["index"]))
                out[key] = int(row["value"])
    return out


def load_arrivals(path):
    """{(flow, seq): delay_us}."""
    out = {}
    with open(path) as f:
        for row in csv.DictReader(f):
            out[(int(row["flow_id"]), int(row["packet_id"]))] = float(row["one_way_delay"]) * 1e6
    return out


def compare_registers(days, ns3):
    # zeros are written on both sides, so a key present on one side only is a
    # real difference in what the pipelines have, not a logging artefact
    keys = set(days) | set(ns3)
    diffs = [(k, days.get(k), ns3.get(k)) for k in sorted(keys)
             if days.get(k) != ns3.get(k)]
    nonzero = sum(1 for k in keys if days.get(k) or ns3.get(k))
    return diffs, len(keys), nonzero


def compare_arrivals(days, ns3):
    common = set(days) & set(ns3)
    only_days = len(days) - len(common)
    only_ns3 = len(ns3) - len(common)
    deltas = [ns3[k] - days[k] for k in common]
    return common, only_days, only_ns3, deltas


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days-log", required=True, help="Days log dir, holding arrivals.csv")
    ap.add_argument("--days-regs", required=True)
    ap.add_argument("--ns3-arrivals", required=True)
    ap.add_argument("--ns3-regs", required=True)
    ap.add_argument("--switch-offset", type=int, default=5,
                    help="Days node id of ns-3 switch 0 (default 5)")
    ap.add_argument("--tolerance-ns", type=float, default=1000.0,
                    help="how far a packet may deviate from the constant offset")
    args = ap.parse_args()

    ok = True

    # ---- what the pipelines did -------------------------------------------
    days_r = load_registers(args.days_regs)
    ns3_r = load_registers(args.ns3_regs, offset=args.switch_offset)
    diffs, total, nonzero = compare_registers(days_r, ns3_r)

    print("파이프라인이 한 일 (레지스터)")
    print(f"  항목 {total}개 (0 아닌 것 {nonzero}개)")
    if diffs:
        ok = False
        print(f"  **{len(diffs)}개 불일치**")
        for (sw, reg, idx), d, n in diffs[:10]:
            print(f"    switch {sw} {reg}[{idx}]:  Days {d}  ns-3 {n}")
        if len(diffs) > 10:
            print(f"    ... {len(diffs) - 10}개 더")
    else:
        print("  일치 ✓  — 모든 스위치가 모든 포트로 모든 플로우를 같은 수만큼 보냄")

    # ---- when the packets arrived ------------------------------------------
    days_a = load_arrivals(Path(args.days_log) / "arrivals.csv")
    ns3_a = load_arrivals(args.ns3_arrivals)
    common, only_days, only_ns3, deltas = compare_arrivals(days_a, ns3_a)

    print()
    print("패킷별 도착 (지연)")
    print(f"  Days {len(days_a)}개, ns-3 {len(ns3_a)}개, 공통 {len(common)}개")
    if only_days or only_ns3:
        ok = False
        print(f"  **한쪽에만 있는 패킷: Days {only_days}, ns-3 {only_ns3}**")
    if not deltas:
        ok = False
        print("  **비교할 패킷이 없다**")
    else:
        offset = statistics.median(deltas)
        spread = [d - offset for d in deltas]
        worst = max(abs(x) for x in spread)
        print(f"  상수 오프셋 (중앙값)  {offset * 1000:8.1f} ns   "
              f"= BMv2 의 홉당 처리비용")
        print(f"  오프셋 대비 최대 편차 {worst * 1000:8.1f} ns")
        print(f"  원시 최대 차이        {max(abs(d) for d in deltas) * 1000:8.1f} ns")
        if worst * 1000 > args.tolerance_ns:
            ok = False
            print(f"  **허용치 {args.tolerance_ns:.0f} ns 초과**")
        else:
            print(f"  허용치 {args.tolerance_ns:.0f} ns 이내 ✓")

    print()
    print("=" * 60)
    print("두 시뮬레이터는 같은 패킷을 같은 경로로 같은 시각에 옮겼다" if ok
          else "차이가 있다 — 위 항목을 확인할 것")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
