#!/usr/bin/env python3
"""scaling.csv -> the table the paper prints.

Speedup is against the same variant at one worker, so the two curves answer
separate questions and can be compared: pure Days says what the runtime can do
on this topology, P4-Days says how much of that survives a pipeline. A P4-Days
curve alone cannot tell a ceiling in the pipeline from a ceiling in Days.
"""
import csv, sys
from collections import defaultdict

def main():
    rows = list(csv.DictReader(open(sys.argv[1])))
    by = defaultdict(dict)
    setup = defaultdict(dict)
    peak = {}
    meta = {}
    for r in rows:
        if not r["seconds"]:
            continue
        by[(int(r["k"]), r["variant"])][int(r["workers"])] = float(r["seconds"])
        if r.get("setup_s"):
            setup[(int(r["k"]), r["variant"])][int(r["workers"])] = float(r["setup_s"])
        peak[(int(r["k"]), r["variant"])] = r.get("peak_rss_mb", "")
        meta[int(r["k"])] = (r["switches"], r["hosts"], r["flows"],
                             r.get("peak_rss_mb", ""))

    for k in sorted(meta):
        sw, hosts, flows, _ = meta[k]
        print(f"\n## k = {k}  ({sw} switches, {hosts} hosts, {flows} flows)")
        ws = sorted(set(by[(k, "pure")]) | set(by[(k, "p4")]))
        print()
        print("| workers | " + " | ".join(str(w) for w in ws) + " |")
        print("|---|" + "---:|" * len(ws))
        for v, label in (("pure", "pure Days (s)"), ("p4", "P4-Days (s)")):
            d = by[(k, v)]
            print(f"| {label} | " + " | ".join(
                f"{d[w]:.3f}" if w in d else "-" for w in ws) + " |")
        for v, label in (("pure", "pure speedup"), ("p4", "P4 speedup")):
            d = by[(k, v)]
            base = d.get(min(ws)) if d else None
            print(f"| {label} | " + " | ".join(
                f"{base/d[w]:.2f}x" if base and w in d else "-" for w in ws) + " |")
        p4, pure = by[(k, "p4")], by[(k, "pure")]
        print("| P4 / pure | " + " | ".join(
            f"{p4[w]/pure[w]:.2f}x" if w in p4 and w in pure else "-"
            for w in ws) + " |")
        for v, label in (("pure", "pure setup (s)"), ("p4", "P4 setup (s)")):
            d = setup[(k, v)]
            if d:
                print(f"| {label} | " + " | ".join(
                    f"{d[w]:.3f}" if w in d else "-" for w in ws) + " |")

        print()
        rp, r4 = peak.get((k, "pure"), ""), peak.get((k, "p4"), "")
        if rp or r4:
            print(f"Peak RSS: pure {rp} MB, P4-Days {r4} MB.")
        s_pure, s_p4 = setup[(k, "pure")], setup[(k, "p4")]
        if s_pure and s_p4:
            mp = sum(s_pure.values()) / len(s_pure)
            m4 = sum(s_p4.values()) / len(s_p4)
            print(f"Setup is serial and does not scale: {mp:.2f} s pure, "
                  f"{m4:.2f} s with a BMv2 instance per switch. It is excluded "
                  f"from the seconds above, which are what Days reports for the "
                  f"simulation itself.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
