#!/usr/bin/env bash
# Handoff section 10, Tests 1-5.
#
# The order matters: each test adds one thing to the one before it, so a failure
# names its own cause. Test 1 forwards without touching the packet; Test 2 edits
# it; Test 3 tells two flows apart; Test 4 keeps state; Test 5 puts two stateful
# switches in a path and checks neither sees the other's.
#
# Every test runs the same topology: host 0 - P4 switch 1 - P4 switch 2 - host 3.
set -u
cd "$(dirname "$0")"
DAYS=../../days
export PATH="$HOME/.cargo/bin:$PATH"

pass=0; fail=0
ok()   { echo "  PASS  $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $1"; fail=$((fail+1)); }

run() {   # $1 = config (relative to the days dir)
  rm -rf "$DAYS/logs/correctness"
  (cd "$DAYS" && ./target/release/days "$1") >/dev/null 2>&1
}

sink()  { sed -n '2p' "$DAYS/logs/correctness/$1/sinks.csv" 2>/dev/null; }
events(){ cat "$DAYS/logs/correctness/$1/p4_events.csv" 2>/dev/null; }
trace() { cat "$DAYS/logs/correctness/$1/bmv2/switch-$2.log" 2>/dev/null; }

echo "building..."
(cd "$DAYS" && cargo build --release --features p4_bmv2) >/dev/null 2>&1 || {
  echo "build failed"; exit 1; }

# ---------------------------------------------------------------- baseline
echo
echo "baseline — the same topology with no P4 switches"
run ../experiments/correctness/configs/baseline.toml
base_sink=$(sink baseline)
[ -n "$base_sink" ] && ok "delivers traffic: $base_sink" || bad "delivered nothing"

# ---------------------------------------------------------------- test 1
echo
echo "Test 1 — passthrough"
run ../experiments/correctness/configs/test1.toml
t1_sink=$(sink test1)
strip() { cut -d, -f2-; }
[ -n "$t1_sink" ] && ok "delivers traffic" || bad "delivered nothing"
if [ "$(echo "$base_sink" | strip)" = "$(echo "$t1_sink" | strip)" ]; then
  ok "identical to the baseline — the pipeline changed nothing"
else
  bad "differs from the baseline"
  echo "        baseline: $base_sink"
  echo "        test1:    $t1_sink"
fi
# every packet visits both switches
hops=$(events test1 | grep -c ',forward,')
[ "$hops" -gt 0 ] && ok "$hops forwarding events recorded" || bad "no P4 events"

# ---------------------------------------------------------------- test 2
echo
echo "Test 2 — header modification"
run ../experiments/correctness/configs/test2.toml
[ -n "$(sink test2)" ] && ok "delivers traffic" || bad "delivered nothing"
# the pipeline edits TTL; sizes are untouched, so delivery still matches
if [ "$(echo "$base_sink" | strip)" = "$(sink test2 | strip)" ]; then
  ok "editing the header did not change delivery"
else
  bad "delivery changed: $(sink test2)"
fi

# the edit itself: switch 1 receives the synthesized 64, switch 2 must receive
# 63. That only holds if the first switch's edit travelled with the packet
# rather than the header being rebuilt at every hop.
ttl1=$(trace test2 1 | grep -o 'TTL_IN pkt=[0-9]* ttl=[0-9]*' | head -1 | grep -o 'ttl=[0-9]*')
ttl2=$(trace test2 2 | grep -o 'TTL_IN pkt=[0-9]* ttl=[0-9]*' | head -1 | grep -o 'ttl=[0-9]*')
if [ "$ttl1" = "ttl=64" ] && [ "$ttl2" = "ttl=63" ]; then
  ok "the header edit survived the hop (switch 1 saw 64, switch 2 saw 63)"
else
  bad "expected 64 then 63, saw '$ttl1' then '$ttl2'"
fi

# ---------------------------------------------------------------- test 3
echo
echo "Test 3 — match/action table, two flows to the same host"
run ../experiments/correctness/configs/test3.toml
flows=$(events test3 | tail -n +2 | cut -d, -f3 | sort -u | tr '\n' ' ')
nflows=$(echo "$flows" | wc -w)
[ "$nflows" -eq 2 ] && ok "both flows forwarded, ids: $flows" \
                    || bad "expected two flows, saw: $flows"
sinks=$(wc -l < "$DAYS/logs/correctness/test3/sinks.csv" 2>/dev/null || echo 0)
[ "$sinks" -ge 3 ] && ok "both flows reached a sink" || bad "sinks.csv has $sinks lines"

# ---------------------------------------------------------------- test 4
echo
echo "Test 4 — stateful register"
run ../experiments/correctness/configs/test4.toml
[ -n "$(sink test4)" ] && ok "delivers traffic" || bad "delivered nothing"
n4=$(events test4 | grep -c ',forward,')
[ "$n4" -gt 0 ] && ok "$n4 forwarding events with state enabled" || bad "no P4 events"

# the state itself: the counter must advance once per packet, not reset
counts=$(trace test4 1 | grep -o 'COUNT n=[0-9]*' | grep -o '[0-9]*' | tr '\n' ' ')
expected=$(seq 1 $(echo "$counts" | wc -w) | tr '\n' ' ')
if [ -n "$counts" ] && [ "$counts" = "$expected" ]; then
  ok "the register advanced 1..$(echo "$counts" | wc -w) across packets"
else
  bad "counter sequence was '$counts', expected '$expected'"
fi

# ---------------------------------------------------------------- test 5
echo
echo "Test 5 — two P4 switches in a path"
run ../experiments/correctness/configs/test5.toml
[ -n "$(sink test5)" ] && ok "delivers traffic" || bad "delivered nothing"

# both switches must appear, and each packet must be seen by both
sw=$(events test5 | tail -n +2 | cut -d, -f2 | sort -u | tr '\n' ' ')
[ "$(echo "$sw" | wc -w)" -eq 2 ] && ok "both switches forwarded: $sw" \
                                  || bad "expected two switches, saw: $sw"

per_packet=$(events test5 | tail -n +2 | cut -d, -f4 | sort | uniq -c | awk '{print $1}' | sort -u | tr '\n' ' ')
[ "$per_packet" = "2 " ] && ok "every packet crossed both switches" \
                         || bad "packets per switch count: $per_packet"

# the BMv2 trace must be split per switch, with no cross-contamination
bad_attr=0
for f in "$DAYS"/logs/correctness/test5/bmv2/switch-*.log; do
  [ -e "$f" ] || continue
  id=$(basename "$f" .log | sed 's/switch-//')
  n=$(grep 'sw=' "$f" | grep -vc "sw=$id ")
  [ "$n" -eq 0 ] || bad_attr=$((bad_attr+1))
done
nlogs=$(ls "$DAYS"/logs/correctness/test5/bmv2/switch-*.log 2>/dev/null | wc -l)
[ "$nlogs" -eq 2 ] && [ "$bad_attr" -eq 0 ] \
  && ok "per-switch BMv2 traces, no cross-attribution" \
  || bad "$nlogs trace files, $bad_attr with foreign lines"

# state isolation, which handoff section 23 requires: each switch counts only
# its own packets, so both must produce 1,2,3,... A shared register would make
# the two sequences interleave into 1,3,5 and 2,4,6.
c1=$(trace test5 1 | grep -o 'COUNT n=[0-9]*' | grep -o '[0-9]*' | tr '\n' ' ')
c2=$(trace test5 2 | grep -o 'COUNT n=[0-9]*' | grep -o '[0-9]*' | tr '\n' ' ')
if [ -n "$c1" ] && [ "$c1" = "$c2" ]; then
  ok "the two switches kept separate state (both counted $c1)"
else
  bad "state leaked between switches: switch 1 '$c1', switch 2 '$c2'"
fi

# the two logs must join on the same key
probe=$(events test5 | sed -n '2p')
if [ -n "$probe" ]; then
  t=$(echo "$probe" | cut -d, -f1); s=$(echo "$probe" | cut -d, -f2)
  fl=$(echo "$probe" | cut -d, -f3); pk=$(echo "$probe" | cut -d, -f4)
  if grep -q "sw=$s flow=$fl pkt=$pk " "$DAYS/logs/correctness/test5/bmv2/switch-$s.log" 2>/dev/null; then
    ok "a CSV row leads to its pipeline lines (t=$t sw=$s flow=$fl pkt=$pk)"
  else
    bad "no pipeline lines for sw=$s flow=$fl pkt=$pk"
  fi
fi

echo
echo "=================================="
echo "  $pass passed, $fail failed"
echo "=================================="
[ "$fail" -eq 0 ]
