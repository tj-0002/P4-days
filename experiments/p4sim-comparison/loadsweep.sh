#!/usr/bin/env bash
# Sweeps the offered load and asks, at each level, whether the two simulators
# agree per flow as well as in aggregate.
#
# The interval is per flow. One 1042-byte frame takes 8.336 us on a 1 Gb/s link,
# so an interval below that saturates a host's own access link: both flows then
# leave their hosts on the same departure grid and the per-flow split stops
# being comparable. Above it the two agree to 0.1 % on everything.
set -u
DAYS=/home/tj/research/p4-days/days
CMP=/home/tj/research/p4-days/experiments/p4sim-comparison
NS3=/home/tj/ns-3.39
SCRATCH=$(mktemp -d)
N=2000

for us in 20 16 14 12 10 8 5; do
  I=$(python3 -c "print(f'{$us/1e6:.9f}')")
  D=$(python3 -c "print(f'{($N-0.005)*$us/1e6:.9f}')")

  python3 - "$I" "$D" <<'PY'
import re, sys
I, D = sys.argv[1], sys.argv[2]
s = open('/home/tj/research/p4-days/experiments/p4sim-comparison/days_config.toml').read()
# match whatever the config currently holds, not a value baked in here
n = r'[0-9.eE+-]+'
s, a = re.subn(rf'arr_dist = \{{type = "Uniform", low = {n}, high = {n}\}}',
               f'arr_dist = {{type = "Uniform", low = {I}, high = {I}}}', s)
s, b = re.subn(rf'^(\s*)duration = {n}$', rf'\g<1>duration = {D}', s, flags=re.M)
assert a == 2 and b == 2, f'config substitution missed: arr_dist {a}, duration {b}'
s = re.sub(r'^log_path = .*$', 'log_path = "logs/m4/sweep"', s, flags=re.M)
open('/tmp/m4_sweep.toml','w').write(s)
PY

  rm -rf "$DAYS/logs/m4/sweep"
  (cd "$DAYS" && ./target/release/days /tmp/m4_sweep.toml) >/dev/null 2>&1
  (cd "$NS3" && ./ns3 run "p4days-compare --p4json=$CMP/m4_compare.json \
      --flowtables=$CMP/flowtables_ns3/ --out=$SCRATCH/sweep.csv \
      --pktCount=$N --interval=$I --switchRate=100000000 --queueMaxPkts=1000") >/dev/null 2>&1

  python3 - "$us" "$DAYS/logs/m4/sweep/arrivals.csv" "$SCRATCH/sweep.csv.arrivals.csv" <<'PY'
import csv, sys, collections
us, dp, np_ = sys.argv[1], sys.argv[2], sys.argv[3]
def load(p):
    d = collections.defaultdict(list)
    for r in csv.DictReader(open(p)):
        d[r['flow_id']].append(float(r['one_way_delay'])*1e6)
    return d
def pct(v, p):
    s = sorted(v); k = (len(s)-1)*p/100.0; lo = int(k); hi = min(lo+1, len(s)-1)
    return s[lo] + (s[hi]-s[lo])*(k-lo)
D, P = load(dp), load(np_)
if not D or not P:
    print(f'{us:>4}us  (데이터 없음)'); sys.exit()
bd = min(v for vs in D.values() for v in vs)
bp = min(v for vs in P.values() for v in vs)
allD = [v/bd for vs in D.values() for v in vs]
allP = [v/bp for vs in P.values() for v in vs]
pool = max(abs(pct(allD,p)-pct(allP,p))/max(pct(allD,p),pct(allP,p)) for p in (50,90,99))
worst, detail = 0.0, []
for f in sorted(set(D)|set(P)):
    a = [v/bd for v in D.get(f,[])]; b = [v/bp for v in P.get(f,[])]
    if not a or not b: worst = 1.0; detail.append(f'{f}:없음'); continue
    e = max(abs(pct(a,p)-pct(b,p))/max(pct(a,p),pct(b,p)) for p in (50,90,99))
    worst = max(worst, e)
    detail.append(f'{f} {len(a)}/{len(b)} {e*100:5.1f}%')
lost = f'{sum(len(v) for v in D.values())}/{sum(len(v) for v in P.values())}'
mark = 'ok' if worst < 0.05 else 'X'
print(f'{us:>4}us  전달 {lost:>10}  합산차 {pool*100:5.2f}%  플로우별 최대차 {worst*100:6.2f}% {mark:>2}   [{"  ".join(detail)}]')
PY
done
