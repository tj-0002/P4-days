#!/usr/bin/env bash
# Derives the ns-3 flow tables from the ones Days exported.
#
# Days names a table after its own switch id (5..8); ns-3 indexes switches from
# 0. Keeping two hand-made copies means that the moment Days routes differently
# -- a different topology, different flows, ECMP landing elsewhere -- the ns-3
# side quietly keeps the old routing and the comparison stops comparing the same
# network, with nothing to show for it.
set -eu
cd "$(dirname "$0")"

FIRST=5          # the lowest Days switch id; ns-3 switch 0
COUNT=4

rm -rf flowtables_ns3
mkdir flowtables_ns3
for j in $(seq 0 $((COUNT - 1))); do
  src="flowtables/flowtable_$((FIRST + j)).txt"
  [ -r "$src" ] || { echo "missing $src -- run the Days side first" >&2; exit 1; }
  cp "$src" "flowtables_ns3/flowtable_$j.txt"
done
echo "flowtables_ns3/ derived from flowtables/ ($COUNT switches, ids $FIRST..$((FIRST + COUNT - 1)) -> 0..$((COUNT - 1)))"
