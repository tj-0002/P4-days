#!/usr/bin/env bash
# Does routing through a P4 pipeline deliver the same traffic as Days alone?
#
# Days picks the path either way; the P4 switches only carry out the decision it
# already made. Anything else in the sink's row means the integration changed the
# simulation, which is the one thing it must not do.
#
# Run from anywhere; paths are resolved relative to this script.
set -u
cd "$(dirname "$0")"
DAYS=../../days
export PATH="$HOME/.cargo/bin:$PATH"

echo "building..."
(cd "$DAYS" && cargo build --release --features p4_bmv2) || exit 1

run() {   # $1 = config, $2 = log dir
  rm -rf "$DAYS/$2"
  (cd "$DAYS" && ./target/release/days "$1") >/dev/null 2>&1
  sed -n '2p' "$DAYS/$2/sinks.csv"
}

baseline=$(run tests/p4_topology_nop4.toml logs/p4_baseline)
with_p4=$(run tests/p4_topology.toml logs/p4_topology)

# the sink id comes from a per-run counter, so compare everything after it
strip_id() { cut -d, -f2-; }
b=$(echo "$baseline" | strip_id)
w=$(echo "$with_p4"  | strip_id)

echo
echo "without P4: $baseline"
echo "with P4:    $with_p4"
echo
if [ -z "$b" ]; then
  echo "FAIL: the baseline delivered nothing"; exit 1
elif [ "$b" = "$w" ]; then
  echo "PASS: identical delivery"
else
  echo "FAIL: P4 switches changed the delivered traffic"; exit 1
fi
