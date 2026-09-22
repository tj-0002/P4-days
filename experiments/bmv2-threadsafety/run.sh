#!/usr/bin/env bash
# Runs the whole experiment end to end. Results land in results/.
set -u
cd "$(dirname "$0")"
mkdir -p results

echo "=== build ==="
make clean >/dev/null && make harness harness-tsan || exit 1

echo; echo "=== stage 1-3: sequential, parallel, equivalence ==="
./harness --mode all --switches 4 --packets 1000 | tee results/functional.log

echo; echo "=== stage 4a: ThreadSanitizer (limited: libbmall is uninstrumented) ==="
TSAN_OPTIONS="history_size=7" setarch "$(uname -m)" -R \
  ./harness-tsan --mode parallel --packets 500 > results/tsan.log 2>&1
echo "data races: $(grep -c 'WARNING: ThreadSanitizer' results/tsan.log || true)  -> results/tsan.log"

echo; echo "=== stage 4b: Helgrind, warmup ON (slow) ==="
valgrind --tool=helgrind --log-file=results/helgrind-warmup.log \
  ./harness --mode parallel --switches 4 --packets 40 >/dev/null 2>&1
echo "data races: $(grep -c 'Possible data race' results/helgrind-warmup.log || true)  -> results/helgrind-warmup.log"

echo; echo "=== stage 4c: Helgrind, warmup OFF (control) ==="
valgrind --tool=helgrind --log-file=results/helgrind-nowarmup.log \
  ./harness --mode parallel --switches 4 --packets 40 --no-warmup >/dev/null 2>&1
echo "data races: $(grep -c 'Possible data race' results/helgrind-nowarmup.log || true)  -> results/helgrind-nowarmup.log"
