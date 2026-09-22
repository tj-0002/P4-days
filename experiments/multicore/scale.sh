#!/usr/bin/env bash
# Does putting BMv2 inside Days keep Days' parallelism?
#
# The paper's motivation is that ns-3 + p4sim is sequential and Days is not, so
# the comparison against p4sim is only half the argument: the other half is that
# P4-Days still scales. Pure Days is measured at every point as the reference,
# because a P4-Days curve on its own cannot say whether a ceiling came from the
# pipeline or from Days.
#
#   ./scale.sh                    k = 8, 16, 32 at 1..16 workers
#   KS=16 WORKERS=1,2,4 ./scale.sh
#   REPS=5 ./scale.sh
#
# k is capped at 32: a BMv2 instance costs about 10.2 MB and k=32 is 1,280 of
# them, 13.4 GB measured. k=64 would be roughly 51 GB.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DAYS="$(cd "$HERE/../../days" && pwd)"

DAYS_P4="${DAYS_P4:-$DAYS/target/bench-nolog/release/days}"
DAYS_PURE="${DAYS_PURE:-$DAYS/target/bench-base/release/days}"
KS="${KS:-8,16,32}"
WORKERS="${WORKERS:-1,2,4,8,16}"
REPS="${REPS:-3}"
CFG="$HERE/configs"
OUT="$HERE/results"

for b in "$DAYS_P4" "$DAYS_PURE"; do
  [ -x "$b" ] || { echo "missing $b" >&2; exit 1; }
done

python3 "$HERE/gen-configs.py" --out "$CFG" --ks "$KS" --workers "$WORKERS" >/dev/null || exit 1
mkdir -p "$OUT"
CSV="$OUT/scaling.csv"
# seconds  = what Days reports, the simulation proper
# wall_s   = the whole process, so setup_s = wall_s - seconds is topology
#            construction plus, in the p4 variant, building one BMv2 instance
#            per switch. That part is serial and does not scale, so it has to
#            be visible rather than folded into the speedup.
echo "k,switches,hosts,flows,workers,variant,seconds,wall_s,setup_s,packets,peak_rss_mb" > "$CSV"

median() { python3 -c 'import statistics,sys; v=[float(x) for x in sys.stdin.read().split()]; print(f"{statistics.median(v):.3f}")'; }

for k in ${KS//,/ }; do
  read -r switches hosts flows < <(python3 -c "
k=$k; e=a=k*k//2; c=(k//2)**2
print(e+a+c, k**3//4, min(4096, max(256,(e+a+c)*4)))")
  echo; echo "=== k=$k  ($switches switches, $hosts hosts, $flows flows) ==="
  printf '%-8s %10s %10s %10s %10s %9s\n' \
         workers 'pure (s)' 'P4 (s)' 'pure setup' 'P4 setup' 'P4/pure'
  for w in ${WORKERS//,/ }; do
    line=""
    for kind in pure p4; do
      bin=$DAYS_PURE; [ "$kind" = p4 ] && bin=$DAYS_P4
      cfgfile="$CFG/k${k}_${kind}_w${w}.toml"
      [ -f "$cfgfile" ] || { line="$line - -"; continue; }
      times=""; walls=""; pkts=""; rss=0
      for _ in $(seq "$REPS"); do
        rm -rf "$DAYS/logs/scale"
        o=$( cd "$DAYS" && /usr/bin/time -f 'PEAKRSS %M WALL %e' "$bin" "$cfgfile" 2>&1 )
        t=$(printf '%s\n' "$o" | sed -n 's/.*Elapsed wall-clock time: \([0-9.]*\) seconds.*/\1/p')
        wl=$(printf '%s\n' "$o" | sed -n 's/.*WALL \([0-9.]*\).*/\1/p')
        if [ -z "$t" ]; then
          echo "  $kind w$w FAILED -- last line: $(printf '%s\n' "$o" | tail -1)"
          times=""; walls=""; break
        fi
        pkts=$(printf '%s\n' "$o" | sed -n 's/.*Total packets processed: \([0-9]*\).*/\1/p')
        m=$(printf '%s\n' "$o" | sed -n 's/.*PEAKRSS \([0-9]*\).*/\1/p')
        [ -n "$m" ] && [ "$m" -gt "$rss" ] && rss=$m
        times="$times $t"; walls="$walls $wl"
      done
      med=""; medw=""; setup=""
      if [ -n "$times" ]; then
        med=$(echo "$times" | median)
        medw=$(echo "$walls" | median)
        setup=$(python3 -c "print(f'{max(0.0, $medw - $med):.3f}')")
      fi
      echo "$k,$switches,$hosts,$flows,$w,$kind,$med,$medw,$setup,$pkts,$((rss/1024))" >> "$CSV"
      line="$line ${med:--} ${setup:--}"
    done
    set -- $line     # $1 pure s  $2 pure setup  $3 p4 s  $4 p4 setup
    cost=$(python3 -c "
a='${1:--}'.strip(); b='${3:--}'.strip()
print(f'{float(b)/float(a):.2f}x' if a not in ('','-') and b not in ('','-') and float(a) else '-')" 2>/dev/null)
    printf '%-8s %10s %10s %10s %10s %9s\n' \
           "$w" "${1:--}" "${3:--}" "${2:--}" "${4:--}" "$cost"
  done
done

echo; echo "-> $CSV"
python3 "$HERE/plot.py" "$CSV" 2>/dev/null || true
