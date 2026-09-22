#!/usr/bin/env bash
# What does a P4 switch cost, on the network the M4 comparison validated?
#
# The same topology, the same links and the same two flows as
# experiments/p4sim-comparison/days_config.toml, run four ways:
#
#   base     pure Days, the p4 feature not compiled in at all
#   unused   p4_bmv2 compiled, no [p4] section -- what the feature costs when off
#   p4       p4_bmv2 with the pipeline running, per-packet event log off
#   p4+log   the same with the event log on
#
# base -> unused is the price of carrying the integration.
# unused -> p4 is the price of the pipeline itself.
# p4 -> p4+log is the price of the CSV row, which is not the pipeline's cost and
# is why it can be turned off.
#
# Each variant is run REPS times and the median is reported: a single run of a
# tenth of a second is mostly noise.
set -eu
cd "$(dirname "$0")"
export PATH="$HOME/.cargo/bin:$PATH"

DAYS=../../days
CMP=../p4sim-comparison
REPS=${REPS:-7}
COUNTS=${COUNTS:-"2000 10000 50000"}
INTERVAL_US=10

echo "building (two target dirs, so the builds do not overwrite each other)..."
(cd "$DAYS" && cargo build --release --target-dir target/bench-base >/dev/null 2>&1)
(cd "$DAYS" && cargo build --release --features p4_bmv2 --target-dir target/bench-p4 >/dev/null 2>&1)
BASE_BIN=$DAYS/target/bench-base/release/days
P4_BIN=$DAYS/target/bench-p4/release/days

cfg() {  # $1 = source config, $2 = out, $3 = duration, $4 = log_events
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import re, sys
src, out, dur, logev = sys.argv[1:5]
s = open(src, encoding='utf-8').read()
n = r'[0-9.eE+-]+'
s, k = re.subn(rf'^(\s*)duration = {n}$', rf'\g<1>duration = {dur}', s, flags=re.M)
assert k == 2, f'duration substitution hit {k} sites'
s = re.sub(r'^log_path = .*$', 'log_path = "logs/bench"', s, flags=re.M)
s = re.sub(r'^(\s*)log_events = \w+$', rf'\g<1>log_events = {logev}', s, flags=re.M)
# the table export is a per-switch file write at setup; irrelevant here
s = re.sub(r'^\s*export_tables_dir = .*$\n', '', s, flags=re.M)
open(out, 'w', encoding='utf-8').write(s)
PY
}

run() {  # $1 = binary, $2 = config -> "<sim_elapsed> <total_wall>"
  rm -rf "$DAYS/logs/bench"
  local t0 t1 out sim
  t0=$(date +%s.%N)
  out=$(cd "$DAYS" && "${1#$DAYS/}" "$2" 2>&1)
  t1=$(date +%s.%N)
  sim=$(printf '%s\n' "$out" | sed -n 's/.*Elapsed wall-clock time: \([0-9.]*\) seconds.*/\1/p')
  [ -n "$sim" ] || { echo "run failed:" >&2; printf '%s\n' "$out" | tail -5 >&2; exit 1; }
  printf '%s %s\n' "$sim" "$(python3 -c "print(f'{$t1-$t0:.3f}')")"
}

median() { python3 -c "
import sys,statistics
v=[float(x) for x in sys.argv[1:]]
print(f'{statistics.median(v):.4f}')" "$@"; }

for N in $COUNTS; do
  DUR=$(python3 -c "print(f'{($N-0.005)*$INTERVAL_US/1e6:.9f}')")
  cfg "$CMP/days_config_nop4.toml" /tmp/bench_base.toml "$DUR" false
  cfg "$CMP/days_config.toml"      /tmp/bench_p4.toml   "$DUR" false
  cfg "$CMP/days_config.toml"      /tmp/bench_p4log.toml "$DUR" true

  # how many pipeline invocations this load actually makes
  rm -rf "$DAYS/logs/bench"
  (cd "$DAYS" && ./target/bench-p4/release/days /tmp/bench_p4log.toml) >/dev/null 2>&1
  HOPS=$(( $(wc -l < "$DAYS/logs/bench/p4_events.csv") - 1 ))
  DELIV=$(( $(wc -l < "$DAYS/logs/bench/arrivals.csv") - 1 ))

  echo
  echo "=== 플로우당 $N 패킷  (전달 $DELIV, P4 파이프라인 호출 $HOPS 회) ==="
  printf '%-10s %12s %12s %14s\n' variant 'sim(s)' 'total(s)' 'us/pipeline'
  printf -- '---------------------------------------------------------\n'
  declare -A SIM
  for v in base unused p4 p4+log; do
    case $v in
      base)   BIN=$BASE_BIN; CFG=/tmp/bench_base.toml ;;
      unused) BIN=$P4_BIN;   CFG=/tmp/bench_base.toml ;;
      p4)     BIN=$P4_BIN;   CFG=/tmp/bench_p4.toml ;;
      p4+log) BIN=$P4_BIN;   CFG=/tmp/bench_p4log.toml ;;
    esac
    sims=(); tots=()
    for _ in $(seq "$REPS"); do
      read -r s t < <(run "$BIN" "$CFG")
      sims+=("$s"); tots+=("$t")
    done
    ms=$(median "${sims[@]}"); mt=$(median "${tots[@]}")
    SIM[$v]=$ms
    per=$(python3 -c "b=${SIM[base]}; print(f'{($ms-b)*1e6/$HOPS:8.3f}' if $HOPS else '     n/a')")
    printf '%-10s %12s %12s %14s\n' "$v" "$ms" "$mt" "$per"
  done
done
