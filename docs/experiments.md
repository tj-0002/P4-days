# Experiments

What was measured, how, what it shows, and what it does not.

The project makes one claim and everything here exists to check both halves of
it:

> **P4-Days runs the same network as ns-3 + p4sim, and runs it faster — without
> losing the parallelism that is the reason for using Days.**

Four experiments, in increasing scope:

| | question | §|
|---|---|---|
| validation | does the integration change what Days does? | [2](#2-validation-does-it-change-days) |
| cross-simulator | does it do the same thing as ns-3 + p4sim, and faster? | [3](#3-does-it-match-ns-3--p4sim-and-beat-it) |
| cost decomposition | what does a P4 switch actually cost, and where does it go? | [4](#4-what-a-p4-switch-costs) |
| scaling | does the parallelism survive? | [6](#6-does-the-parallelism-survive) |

All numbers are from this machine (31 GB RAM, sixteen usable workers), this
BMv2 build and these programs. Reproduce with [usage.md](usage.md#4-reproducing-the-experiments).

---

## 1. How the comparison is made fair

Three things had to be true before any number meant anything, and each was got
wrong first.

**Both simulators must link the same BMv2 build.** `libbmv2` as commonly
installed is compiled with `BM_LOG_DEBUG_ON` and `BM_ELOG_ON`. These are not
runtime log levels: `match_tables.cpp` constructs a `std::ostringstream`, dumps
the matched entry into it and returns a heap string on **every table hit**, as a
macro argument, and the log level then discards the result. Nothing is ever
printed and it is about **72 %** of what a P4 switch costs. Giving P4-Days a
logging-free build and p4sim a stock one measures build configuration, so every
result below is reported twice, once per build, with the same library on both
sides.

**Both simulators must run the same network.** A topology written once per
simulator is a topology that will disagree — P4 tables are keyed by port
number, port numbers come from the order links are declared, and a mismatch
there does not announce itself. So one file generates both. **Days runs first**:
it assigns port numbers, runs the ECMP hash (over `flow_id`, `source_host` and
`sink_host`, values a P4 program cannot see) and exports both as
`ports_<id>.csv` and `flowtable_<id>.txt`. The ns-3 side reads what Days
produced and computes neither.

**Both must carry the same packet.** Days' `packet.size` is wire bytes; ns-3's
`pktSize` is UDP payload. 1000 + 8 UDP + 20 IPv4 + 14 Ethernet = **1042**.
Telling Days 1000 gives it a 4 % faster link, which is invisible at low load
and produces a 94 % disagreement at exactly 100 % offered load, because one
simulator sits below saturation and the other above it.

## 2. Validation: does it change Days?

Three layers, increasing in strength.

**Staged functional tests** (`experiments/correctness/`, 18 checks). Five tests
run in order, each adding exactly one thing: passthrough → header edit (TTL
decrement) → match/action → register persistence at one switch → two switches,
state isolated. The order is not decoration: a failure at step *n* has a
bounded set of causes because 1..*n*−1 passed.

**The build stays clean in all three configurations.**

```
default build (no p4 code compiled)   177 passed, 0 failed
--features p4                         219 passed, 0 failed
--features p4_bmv2                    219 passed, 0 failed
```

The 42 extra are this work's own. Every upstream file the branch touches is
modified only inside `#[cfg]`, so the default build contains no P4 code and
needs no C++ toolchain.

**Equivalence with unmodified Days** is the strongest internal claim: routing a
simulation through P4 switches must deliver exactly what Days delivers without
them, because the P4 switches only carry out a decision Days already made.
`experiments/p4-equivalence/run.sh` runs the same topology with and without the
`[p4]` section and compares the sink rows. **Identical**, including in overload,
where the per-flow split is byte for byte the same.

## 3. Does it match ns-3 + p4sim, and beat it?

### 3.1 The scenarios

Sixteen: four topologies × two traffic patterns (incast, permutation) × two
offered loads (0.6, 1.5). Uniform 1 Gbps links, 1 µs propagation, 1042-byte
frames (8.336 µs on the wire, so a link carries 119,962 pps), 1000-packet
tail-drop buffers, open-loop UDP, `routing = "ECMP"`.

| | topology | switches | hosts | ECMP paths | shape from |
|---|---|---:|---:|---:|---|
| T1 | single bottleneck | 2 | 8 | 1 | DCTCP §2.2 |
| T2 | leaf-spine | 6 | 16 | 2 | VL2 / DCQCN |
| T3 | three-tier Clos | 10 | 16 | 4 | DCQCN figure 2 |
| T4 | fat-tree k=4, 2:1 | 20 | 32 | 4 | PowerTCP / HPCC |

**Why open loop and not TCP.** The comparison is of a *network model*. With TCP
the two would run two different transport implementations — Days has its own
Reno/Cubic/BBR, ns-3 has its own — and any disagreement could not be attributed
to the network. Driving the network with a known arrival process is what makes
the result mean something. That the integration does not disturb Days' TCP is a
separate, closed-loop check against unmodified Days (§2).

**Why link rates are uniform.** Days charges one `port_rate` to every port, so
the oversubscribed topologies these papers actually use cannot be expressed.
The shapes are taken from them; the rates are made uniform.

**Two runs per scenario.** `forward_verify.p4` keeps four register arrays per
switch and is used for the agreement check; `forward.p4` is the same program
without them and is used for timing, because a register access costs about a
microsecond a hop and would be measured as if it were the pipeline's cost. Both
runs must deliver the same traffic, which is itself a check.

### 3.2 Do they do the same thing?

`registers` is exact: every switch forwarded the same number of each flow out
each port, so paths and drops both match. `header` is the separate question of
whether the pipeline *wrote* the same thing — the program decrements TTL at
every hop and the registers sum it after the edit, so a side that skipped it
would pass every other column. `offset` and `spread` are packet serialisation
times.

| scenario | topo | pattern | load | hotspot | delivered | registers | header | offset | spread |
|---|---|---|---:|---:|---:|:---:|:---:|---:|---:|
| S1 | T1 | incast | 0.6 | 0.60x | equal | yes | yes | 3.42 | 0.18 |
| S2 | T1 | incast | 1.5 | 1.50x | equal | yes | yes | 3.68 | 0.46 |
| S3 | T1 | permutation | 0.6 | 0.60x | equal | yes | yes | 3.42 | 0.18 |
| S4 | T1 | permutation | 1.5 | 1.50x | equal | yes | yes | 3.68 | 0.46 |
| S5 | T2 | incast | 0.6 | 0.60x | equal | yes | yes | 4.32 | 0.00 |
| S6 | T2 | incast | 1.5 | 1.50x | equal | yes | yes | 4.32 | 8.00 |
| S7 | T2 | permutation | 0.6 | 1.20x | equal | yes | yes | 3.96 | 1.35 |
| S8 | T2 | permutation | 1.5 | 3.00x | equal | **no** | **no** | 3.44 | 1.85 |
| S9 | T3 | incast | 0.6 | 0.60x | equal | yes | yes | 6.48 | 1.07 |
| S10 | T3 | incast | 1.5 | 1.50x | equal | yes | yes | 6.48 | 4.00 |
| S11 | T3 | permutation | 0.6 | 1.20x | equal | **no** | **no** | 6.06 | 2.36 |
| S12 | T3 | permutation | 1.5 | 3.00x | **283,664 / 319,030** | **no** | **no** | 4.97 | 1000.08 |
| S13 | T4 | incast | 0.6 | 0.60x | equal | yes | yes | 6.48 | 0.01 |
| S14 | T4 | incast | 1.5 | 1.50x | equal | **no** | **no** | 6.49 | 13.00 |
| S15 | T4 | permutation | 0.6 | 1.20x | equal | yes | yes | 6.11 | 1.10 |
| S16 | T4 | permutation | 1.5 | 3.00x | 327,982 / 327,981 | **no** | **no** | 4.95 | 250.23 |

**Registers identical in 11 of 16.** The result sorts by the `hotspot` column,
not by `load`: `load` was declared against an access switch's uplink, and ECMP
then concentrates flows onto a few core ports, so the busiest single output
port is up to twice as oversubscribed as declared.

```
hotspot <= 1.0   exact agreement, every scenario
hotspot  1.2     agreement in two of three
hotspot  1.5     agreement in two of three
hotspot  3.0     per-flow allocation diverges in all three
```

**The constant offset is structural and is reported, not corrected for.**
ns-3 + p4sim queues twice in series — BMv2's egress buffer, then the device
transmit queue — where Days has one scheduler queue per port. At 1000 packets
each the ns-3 side sits about four packets deeper, and BMv2 also charges a
per-packet cost at a finite `SwitchRate` that Days does not model. Together they
make every packet late by a fixed amount per hop, which is why the offset tracks
hop count (3.4 at two hops, 4.3 at three, 6.5 at four). What is compared is the
spread around it. Lowering ns-3's device queue to 996 removes the offset; that
was done once as a diagnostic and not adopted, because tuning a parameter until
numbers agree is fitting rather than measuring.

### 3.3 End-to-end delay, as distributions

Microseconds, one-way, `Days / ns-3`.

| scenario | p50 | p99 | | scenario | p50 | p99 |
|---|---|---|---|---|---|---|
| S1 | 26.5 / 55.0 | 28.0 / 55.0 | | S9 | 56.0 / 110.0 | 59.6 / 115.6 |
| S2 | 8358 / 8388 | 8361 / 8391 | | S10 | 8386 / 8438 | 8409 / 8460 |
| S3 | 26.5 / 55.0 | 28.0 / 55.0 | | S11 | 69.1 / 116.6 | 8406 / 8456 |
| S4 | 8358 / 8388 | 8361 / 8391 | | **S12** | **13464 / 11826** | **27565 / 25109** |
| S5 | 37.3 / 73.4 | 37.3 / 73.4 | | S13 | 56.0 / 110.0 | 56.0 / 110.0 |
| S6 | 8371 / 8407 | 8421 / 8409 | | S14 | 8389 / 8443 | 8467 / 8446 |
| S7 | 44.5 / 78.2 | 8376 / 8408 | | S15 | 66.5 / 116.6 | 8405 / 8456 |
| S8 | 8376 / 8405 | 8387 / 8409 | | **S16** | **16722 / 8446** | **18815 / 16781** |

Where a queue is saturated the median is pinned at the buffer drain time
(1000 × 8.336 µs = 8336 µs) on both sides, which is why so many rows read
~8.4 ms. The two bolded scenarios are 3.0x hotspots where the allocation itself
diverged, so their distributions are over different sets of surviving packets
and are not comparable term by term.

Percentiles alone would be weak evidence — two runs can deliver every packet at
a different moment and still produce identical percentiles — which is why the
per-packet join in the `spread` column is the actual test and this table is
context.

### 3.4 How long does each take?

Wall clock, median of three runs.

| scenario | switches | flows | pure Days | P4-Days | ns-3 + p4sim | ratio | P4-Days (stock) | ns-3 (stock) | ratio |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| S1 | 2 | 4 | 0.141 | 0.306 | 0.765 | 2.50x | 0.594 | 1.171 | 1.97x |
| S2 | 2 | 4 | 0.279 | 0.655 | 1.470 | 2.24x | 1.220 | 2.313 | 1.90x |
| S3 | 2 | 4 | 0.141 | 0.304 | 0.766 | 2.52x | 0.595 | 1.172 | 1.97x |
| S4 | 2 | 4 | 0.282 | 0.647 | 1.493 | 2.31x | 1.226 | 2.308 | 1.88x |
| S5 | 6 | 12 | 0.191 | 0.436 | 1.097 | 2.52x | 0.873 | 1.687 | 1.93x |
| S6 | 6 | 12 | 0.428 | 1.044 | 2.382 | 2.28x | 2.070 | 3.909 | 1.89x |
| S7 | 6 | 16 | 1.402 | 3.243 | 7.372 | 2.27x | 6.603 | 12.347 | 1.87x |
| S8 | 6 | 16 | 2.574 | 6.696 | 13.894 | 2.07x | 12.204 | 23.194 | 1.90x |
| S9 | 10 | 12 | 0.255 | 0.607 | 1.497 | 2.47x | 1.243 | 2.363 | 1.90x |
| S10 | 10 | 12 | 0.559 | 1.435 | 3.368 | 2.35x | 2.947 | 5.548 | 1.88x |
| S11 | 10 | 16 | 2.082 | 5.095 | 11.875 | 2.33x | 10.736 | 19.711 | 1.84x |
| S12 | 10 | 16 | 3.142 | 9.658 | 18.784 | 1.94x | 16.570 | 31.429 | 1.90x |
| S13 | 20 | 15 | 0.295 | 0.734 | 1.777 | 2.42x | 1.465 | 2.743 | 1.87x |
| S14 | 20 | 15 | 0.651 | 1.689 | 3.799 | 2.25x | 3.481 | 6.330 | 1.82x |
| S15 | 20 | 16 | 2.078 | 5.193 | 11.941 | 2.30x | 10.674 | 19.942 | 1.87x |
| S16 | 20 | 16 | 3.157 | 9.139 | 18.678 | 2.04x | 16.372 | 31.443 | 1.92x |

| BMv2 build on both sides | range | median |
|---|---|---|
| stock | 1.82x – 1.97x | **1.90x** |
| logging-free | 1.94x – 2.52x | **2.30x** |

**The ratio does not move with topology size.** Two switches to twenty, four
flows to sixteen, 0.14 s to 9.7 s of work. What little variation there is
tracks congestion, not size — the four lowest ratios are all scenarios whose
queues stay full, for the reason in §5.

**P4-Days costs 2.16x to 3.07x unmodified Days**, median 2.44x. That is the
price of executing the pipeline.

### 3.5 Is the speed comparison like for like?

The obvious objection: if the two allocate bandwidth differently, did they do
the same amount of work? Total pipeline invocations, from the register dumps:

| | Days | ns-3 | | | Days | ns-3 |
|---|---:|---:|---|---|---:|---:|
| S1 | 71,976 | 71,976 | | S9 | 155,948 | 155,948 |
| S2 | 150,952 | 150,952 | | S10 | 389,896 | 389,896 |
| S3 | 71,976 | 71,976 | | S11 | 1,428,524 | 1,428,524 |
| S4 | 150,952 | 150,952 | | **S12** | **2,191,002** | **2,219,412** |
| S5 | 107,964 | 107,964 | | S13 | 179,925 | 179,925 |
| S6 | 269,928 | 269,928 | | S14 | 449,847 | 449,850 |
| S7 | 841,718 | 841,718 | | S15 | 1,406,532 | 1,406,532 |
| S8 | 1,573,528 | 1,573,528 | | S16 | 2,159,588 | 2,159,585 |

**Fifteen of sixteen agree to 0.00 %**, including S8, S11 and S14 where the
per-flow allocation diverged. What diverges is *which flow* the work was done
for; *how much* work there was is the same, and that is what the timing
measures. S12 is the exception at +1.30 %, and it runs the other way: ns-3 did
more work and was still 1.94x slower, so the figure understates P4-Days there.

---

## 4. What a P4 switch costs

### 4.1 Do not quote a multiplier

The multiple is not a property of the integration:

```
                            hops/pkt   Days itself   BMv2         multiple
4-switch network               3.64    1.57 us/hop   6.27 us/hop    4.96x
k=8 fat-tree, 80 switches      4.82    0.65 us/hop   7.39 us/hop   12.33x
```

The same pipeline costs about the same in both. What changes is how much Days
work each hop carries, and the multiple is the ratio of the two. A network
where Days does less per hop reports a bigger multiple of the same cost.
**Quote the per-invocation cost.**

### 4.2 Where the time goes

Per packet-hop, logging-free build, on a network with no congestion:

```
stage      us/call   share   what it is
parse       0.3195   26.0%   BMv2, the program's parser
ingress     0.2629   21.4%   BMv2, the table lookup
meta        0.2424   19.7%   reset_metadata -- must stay, see below
newpkt      0.1447   11.8%   bm::Packet + PacketBuffer + a PHV from the pool
deparse     0.1052    8.6%   BMv2
free        0.1013    8.2%   destructor, PHV back to the pool
other       ~0.05
            1.2293
Rust + FFI  0.240            synthesis, reverse mapping, six FFI calls
            1.469 a hop
```

Nothing here is waste. `parse + ingress + deparse` (0.69 µs) is BMv2 doing the
work it exists to do. `newpkt + free` (0.25 µs) is one `bm::Packet` per hop;
reusing one across hops is the only structural win left, and BMv2 offers no
public way to refill a packet in place.

`phv->reset_metadata()` is most of `meta`, and BMv2's own comment on it reads
`// so slow I want to die`. **It must stay.** `PHV::reset()`, which runs when a
PHV returns to the pool, only marks headers invalid — it does not zero
metadata. Without the explicit reset a packet would read the previous packet's
metadata out of a recycled PHV: wrong, and non-deterministically wrong under
multiple workers. p4sim calls it per packet too.

**The floor for this design is 1.2–1.5 µs per packet-hop**, and the part this
work wrote — synthesis, reverse mapping and the FFI — is 0.24 µs of it.

### 4.3 How it got there

```
                              us/call   multiple over pure Days
as first measured              6.100    4.86x  (4-switch) / 11.93x (k=8)
logging off + the three below  1.496    1.95x                / 3.86x
```

**BMv2 debug logging: 72 %.** Described in §1. It is two builds, not a setting
— `BMV2_PREFIX` selects between them, so no code changes.

**Field handles instead of names: ~8 %.** `PHV::get_field(name)` is
`fields_map.at(std::string)`, a hash lookup of about 70 ns, and the shim did
five a hop. The PHV layout belongs to the program, not to a packet, so it is
resolved once on the first packet and used as `get_field(header_id, offset)`,
an array index. `spec` 0.0678 → 0.0161 µs; `meta` 0.3545 → 0.2467 µs.

**Two heap allocations a hop, on the Rust side.** `run_pipeline` cloned the
synthesized header into a fresh `Vec` before handing it to the shim — which
copies it into BMv2's buffer anyway — and `bytes()` allocated another `Vec` for
the deparsed bytes only to assign it over the previous one. Now a slice and an
in-place write: 1.635 → 1.469 µs.

**Buffer headroom: ruled out.** The packet buffer is allocated with 512 bytes of
slack for a program that pushes headers. 128 instead gives 1.460 vs 1.469 µs,
i.e. nothing. Left at 512.

> **A measurement trap worth reporting.** The first numbers came out at 9.58 µs
> a hop. A third of that was debugging code *inside the P4 program*: it counted
> packets in a register and called `log_msg` twice, once with four arguments,
> on every packet. `log_msg` costs even when nothing is listening, because its
> arguments are evaluated and formatted regardless.
>
> ```
> with the debug code      ingress 6.94 us   total 9.09 us
> without                  ingress 3.80 us   total 5.82 us
> ```
>
> Before quoting a per-packet cost, read the program's `apply` block.

---

## 5. What real `queueing_metadata` costs

Moving egress to the dequeue path ([architecture.md §5](architecture.md#5-where-the-pipeline-sits))
makes `deq_qdepth` and `deq_timedelta` real. It is not free, and the cost is
not a constant. Re-running the sixteen with egress back to back inside the
switch — same binary otherwise, same scenarios:

| mean packets resident in a queue | scenarios | cost of the split |
|---:|---|---:|
| 0 (no congestion) | S1, S3, S5, S13 | **+12 % to +16 %** |
| 209 | S7, S11 | +21 % to +24 % |
| 975 | S2, S4, S6, S8, S10, S14 | +23 % to +37 % |
| 1854 (two saturated hops in series) | S12 | **+55 %** |

Spearman ρ between mean queue residency and the cost of the split is **0.952**
over the fourteen scenarios measured.

### 5.1 The evidence that it is locality, not work

S1 and S2 are the same topology, the same two switches and the same four flows;
only the offered load differs, taking mean queue residency from 0 to 975.
`P4D_PROFILE=1` gives per-stage cost in µs per call:

| stage | runs at | S1 (0 resident) | S2 (975 resident) | change |
|---|---|---:|---:|---:|
| `parse` | enqueue | 0.3205 | 0.3209 | **+0.1 %** |
| `meta` | enqueue | 0.2384 | 0.2457 | +3.1 % |
| `ingress` | enqueue | 0.2811 | 0.2757 | **−1.9 %** |
| `newpkt` | enqueue | 0.1331 | 0.2435 | **+83 %** |
| `egress` | **dequeue** | 0.0147 | 0.0147 | **0.0 %** |
| `deparse` | **dequeue** | 0.1031 | 0.1619 | **+57 %** |
| `free` | dequeue | 0.1010 | 0.1189 | +18 % |
| total | | 1.2465 | 1.4170 | +13.7 % |
| peak RSS | | 40.3 MB | 62.6 MB | +55 % |

Read it three ways:

- **The pipeline stages that run before the queue do not move.** `parse` is
  identical to the fourth decimal and `ingress` is slightly *faster*. The
  program does exactly the same work.
- **`egress` itself does not move either** — 0.0147 µs in both, because
  `forward.p4`'s egress control is empty. **None of the cost is running egress
  later.** Deferring the stage is free; keeping the packet alive in order to
  defer it is not.
- **What moves is every stage touching memory across the queue boundary.**
  `deparse` is the first thing to touch the packet after dequeue and pays +57 %
  in cache misses; `newpkt` pays +83 % drawing from a PHV pool that must now
  hold a thousand live PHVs instead of one, and `free` +18 % returning to it.

Same pattern at scale: S5 (no congestion, 79.6 MB) against S12 (1854 resident,
**375.6 MB**) gives `parse` +12 % and `deparse` +120 %.

**Where the remaining win is.** The cost is proportional to how many
`bm::Packet`s are alive at once, so releasing the PHV at enqueue and taking a
fresh one at dequeue — carrying only the deparsed bytes through the queue —
would cap the pool at the number of workers rather than packets in flight. That
is a design change, not a tuning knob, and has not been attempted.

### 5.2 Two things the split did not change

- **Behaviour is bit-identical.** Same 11 of 16 register agreement over the same
  set, same `spread` in every row, same invocation counts to the digit.
- **The stock-BMv2 ratio does not move** (1.89x before, 1.90x after). ns-3 +
  p4sim already runs egress behind its queue, so it was already paying this.
  The split makes the two comparable in structure as well as in result.

The logging-free ratio fell from 2.87x to 2.30x because that column divides by
a P4-Days number that grew while the ns-3 number did not.

---

## 6. Does the parallelism survive?

The comparison against p4sim is only half the argument: ns-3's event core is
sequential, so winning there says P4-Days is a faster *sequential* simulator.

**P4-Days scales better than unmodified Days**, at all fifteen points measured.

### 6.1 Method

Fat-trees at k = 8, 16, 32 × workers 1, 2, 4, 8, 16 × {pure Days, P4-Days},
three repetitions, medians (`experiments/multicore/scale.sh`). Pure Days is
measured at every point rather than once, because a P4-Days curve alone cannot
distinguish a ceiling in the pipeline from a ceiling in Days.

Two things had to be right, and both were got wrong first — each producing a
confidently wrong answer.

**The workload is held at about 3 million packets at every k**, by solving for
the flow duration. At the generator's earlier fixed duration k=8 finished in
0.22 s, where process start-up and topology construction are most of the
measurement.

| k | switches | hosts | flows | duration | packets |
|---|---:|---:|---:|---:|---:|
| 8 | 80 | 128 | 320 | 9,375 | 3,000,000 |
| 16 | 320 | 1,024 | 1,280 | 2,344 | 3,000,320 |
| 32 | 1,280 | 8,192 | 4,096 | 732 | 2,998,272 |

**Set-up is measured separately and excluded.** `seconds` is what Days reports
for the simulation; `wall_s` is the whole process; `setup_s` the difference.
Set-up is serial — topology construction, routing, and in the P4 variant one
BMv2 instance per switch — and at k=32 it is **97.7 s against a 26.3 s
simulation**. Folded in, pure Days' 16-worker speedup would read 1.2x instead
of 3.96x and the experiment would conclude the opposite of the truth.

### 6.2 The curves

Speedup against the same variant at one worker.

**k = 8** — 80 switches, 128 hosts, 320 flows

| workers | 1 | 2 | 4 | 8 | 16 |
|---|---:|---:|---:|---:|---:|
| pure Days (s) | 1.612 | 1.294 | 0.981 | 0.828 | 0.805 |
| P4-Days (s) | 8.472 | 4.849 | 2.970 | 2.807 | 2.998 |
| pure speedup | 1.00x | 1.25x | 1.64x | 1.95x | 2.00x |
| **P4 speedup** | 1.00x | **1.75x** | **2.85x** | **3.02x** | 2.83x |
| P4 / pure | 5.26x | 3.75x | 3.03x | 3.39x | 3.72x |

**k = 16** — 320 switches, 1,024 hosts, 1,280 flows

| workers | 1 | 2 | 4 | 8 | 16 |
|---|---:|---:|---:|---:|---:|
| pure Days (s) | 11.407 | 6.394 | 3.966 | 2.789 | 2.297 |
| P4-Days (s) | 56.068 | 30.171 | 17.091 | 12.993 | 11.210 |
| pure speedup | 1.00x | 1.78x | 2.88x | 4.09x | 4.97x |
| **P4 speedup** | 1.00x | 1.86x | 3.28x | 4.32x | **5.00x** |
| P4 / pure | 4.92x | 4.72x | 4.31x | 4.66x | 4.88x |

**k = 32** — 1,280 switches, 8,192 hosts, 4,096 flows

| workers | 1 | 2 | 4 | 8 | 16 |
|---|---:|---:|---:|---:|---:|
| pure Days (s) | 26.325 | 14.903 | 10.234 | 7.935 | 6.653 |
| P4-Days (s) | 101.552 | 53.065 | 31.486 | 23.711 | 19.552 |
| pure speedup | 1.00x | 1.77x | 2.57x | 3.32x | 3.96x |
| **P4 speedup** | 1.00x | 1.91x | 3.23x | 4.28x | **5.19x** |
| P4 / pure | 3.86x | 3.56x | 3.08x | 2.99x | 2.94x |

### 6.3 Reading them

**P4-Days is at or above pure Days at all fifteen points.** At k=32 and sixteen
workers it is 5.19x against 3.96x. The integration does not cost parallelism;
it adds work that parallelises better than the work already there.

**The mechanism is visible in the `P4 / pure` row, which falls as workers are
added** — at k=32, 3.86x at one worker down to 2.94x at sixteen. Executing a
pipeline is per-switch CPU work with no state shared between switches, so it
spreads almost perfectly; Days' own event scheduling retains a serial
component, and adding cores dilutes the pipeline's share first. **That row is
also the evidence that no global lock was introduced**: a lock around the
engine would make this ratio *rise*.

**Where a curve bends, it bends for lack of work.** k=8 is the only case that
regresses (3.02x at eight workers to 2.83x at sixteen) and it is 80 switches
over 16 workers — five each. Pure Days flattens at the same point, 1.95x to
2.00x. At k=16 and k=32 neither curve has bent by sixteen workers, and the one
closer to bending is pure Days.

**Do not read `P4 / pure` here as the cost of the pipeline in general.** It is
2.94x–5.26x here against 2.16x–3.07x in §3.4, on a different program and slower
links — §4.1 is the reason. What this section rests on is how the ratio *moves*
with workers, which is scale-free.

### 6.4 Memory, and why k = 32 is the cap

| | pure Days | P4-Days | per P4 switch |
|---|---:|---:|---:|
| k = 8 (80 switches) | 14 MB | 879 MB | 10.81 MB |
| k = 16 (320) | 56 MB | 3,477 MB | 10.69 MB |
| k = 32 (1,280) | 272 MB | **13,591 MB** | 10.41 MB |

A BMv2 instance costs about **10.5 MB**, steady across a 16x range of switch
count. k=32 at 13.6 GB fits a 31 GB machine; k=64 would be 5,120 switches and
roughly 54 GB, which does not. **This is the limit of one `bm::Switch` per
simulated switch, and it is a memory limit rather than a time limit.**

Instantiating them is linear and cheap: `p4 setup − pure setup` gives **4.17,
3.94 and 4.07 ms per switch** at k = 8, 16, 32. (The k=32 one-worker sample is
excluded from that mean: it reads 91.0 s against 102–105 s for every other
point in the same block, the first run against a cold page cache.)

---

## 7. Where the two simulators do not agree, and why neither is wrong

Above a certain load they allocate bandwidth differently among competing flows.

### 7.1 Where it diverges, exactly

Following one flow hop by hop through the S16 register dumps:

```
flow 1:  edge33 -> agg41 -> core50 -> agg45 -> edge37
  sw 33 port 4   44,986 / 44,986    same
  sw 41 port 3   44,986 / 44,986    same
  sw 50 port 2   44,986 /  1,000    <- first difference
  sw 45 port 0   44,986 /  1,000    follows
  sw 37 port 0   44,986 /  1,000    follows

flow 5:  edge34 -> agg41 -> core50 -> agg45 -> edge38
  sw 50 port 2    8,357 / 44,986    <- the exact opposite
```

**The registers count at ingress, before the output queue can drop anything**,
so a count that matches at switch *s* and differs at *s*+1 means the drop
happened in *s*'s output queue. The contention is at agg41's output port 3.

And it matters which input ports the competing packets arrived on:

```
ports_41.csv:  port 0 -> edge33     flow 1 arrives here
               port 1 -> edge34     flow 5 arrives here
               port 3 -> core50     both leave here
```

Different input links. That is the whole story.

### 7.2 The mechanism

**Without congestion there is no decision to make.** Every arriving packet is
forwarded; the output is fixed by arrival times and the service rate, and two
correct implementations compute the same thing.

**When the buffer is full, a decision appears:**

```
time T:  a packet departs, freeing one slot
time T:  packets of flow A and flow B arrive
         whichever is processed first takes the slot; the other is dropped
```

Both simulators agree on the simulated *time*. They differ on which of two
events *at the same simulated time* is processed first — Days takes them in the
order its actor runtime delivers messages, ns-3 in the order its event scheduler
pops them. Neither order means anything physical.

**It locks in rather than scattering.** The winner's packet enters the queue and
frees its slot in phase with that same flow's next arrival, so it keeps winning:

```
A wins a slot  ->  A's packet enters the queue
               ->  when it departs, the slot frees in phase with A's next arrival
               ->  A wins again  ->  B meets a full queue every time
```

**The evidence is exact.** In S16, flow 65537:

```
ns-3:   1,000 packets, sequence numbers 0..999, zero gaps
Days:  44,986 packets, all of them,          zero gaps
```

1,000 is not a coincidence — it is `capacity`. The flow got through only while
the buffer was filling for the first time and never won a slot again. Zero gaps
proves the cut-off is sharp rather than probabilistic. At a 1.2x hotspot the
same flow shows **14,497 gaps**: winning and losing alternately, never locking
in. That is why mild overload produces small differences and heavy overload
produces collapse.

### 7.3 "So which one is right?"

**Neither, and the question is not well posed for either model.**

Two packets cannot arrive at the same instant on the same link, because a link
carries one bit at a time. Simultaneous arrival happens **only across different
input ports** — which is exactly the case in §7.1, flow 1 on port 0 and flow 5
on port 1.

A real switch resolves that with an **input arbiter**: round robin, strict
priority, iSLIP, whatever the chip implements. It is a defined, documented
policy, and it is what decides the outcome in hardware.

**Neither simulator models input arbitration.** Days keeps one FIFO per output
port and enqueues in the order the runtime hands it messages; ns-3 enqueues in
the order the event scheduler pops events. Both model a switch with no
arbitration policy, so the outcome falls out of the implementation rather than
out of the model.

This is not two answers to one question. **It is a question neither model
defines.**

**Make it well posed and they agree**: specify an arbitration policy in both, or
keep every link below persistent saturation. In that regime the agreement is
exact — registers equal as integers, delivery equal, per-packet delay within
one packet serialisation time.

### 7.4 Why this is scoping and not dodging

- **The condition is decidable in advance.** How many flows land on each output
  port is computable from the routing Days exports, before anything runs. It is
  a stated precondition, not an excuse found afterwards.
- **The field already works this way.** HPCC, PowerTCP and DCQCN report FCT
  distributions over many flows, not exact per-flow allocations. Their workloads
  draw flow sizes from a distribution, so arrivals are not periodic and the
  lock-in never forms. These scenarios are unusually deterministic and expose it
  in its purest form.
- **It is not the integration.** In the scenarios where ns-3 differs, pure Days
  and P4-Days produce byte-identical per-flow results. S16:

  | flow | pure Days | P4-Days |
  |---|---:|---:|
  | 65537 | 44,986 | 44,986 |
  | 131074 | 44,986 | 44,986 |
  | 196611 | 15,996 | 15,996 |
  | 262148 | 15,997 | 15,997 |
  | 327685 | 8,357 | 8,357 |
  | 393222 | 8,639 | 8,639 |
  | total | 327,982 | 327,982 |

### 7.5 Telling this apart from a real bug

Signature of the phenomenon:

- registers match at switch *s* and differ at *s*+1, with *s* feeding *s*+1
- the competing flows enter *s* on **different** input ports
- one flow's delivered count equals `capacity` exactly, with **zero gaps** in
  its sequence numbers
- the winner and loser are swapped between the two simulators
- totals at upstream switches match exactly
- **pure Days reproduces P4-Days exactly**

A real bug looks different: counts differing at the *first* hop, a flow missing
entirely, TTL sums disagreeing, or pure Days disagreeing with P4-Days.

---

## 8. What went wrong on the way here

Every one of these was silent — no error message, a plausible-looking result.
They are listed because anyone reproducing this can hit them.

**ns-3's real queue was ten times smaller than Days'.** `QueueBufferSize`
reaches `bm::QueueingLogicPriRL` as a **packet count** despite its name, but
the queue that actually filled was `CustomP2PNetDevice`'s DropTail at ns-3's
100-packet default. Fixed with `p2p.SetQueue(..., QueueSize(PACKETS, n))`.

**A missing trailing slash emptied every P4 table.** `--flowtables` without it
gives `<dir>flowtable_0.txt`, which does not exist, so every table was empty and
everything hit the default `drop` action. No error: the run reported "sent 2000,
received 0". Fixed with path normalisation and an explicit existence check.

**Frame size versus payload size.** Days was told 1000 where ns-3 sent a
1042-byte frame — §1. 94 % disagreement at exactly 100 % load.

**L4 port collision on the ns-3 side.** With `flow_id = 65537 + i` every flow's
high half is 1, so every sender bound source port 1. In a permutation a host
both sends and receives, binds port 1 twice, and the receiving socket loses —
one flow delivered nothing on the ns-3 side while Days delivered it in full.
Days never noticed because there the ports are values a table matches on, not
sockets. Fixed by putting `(i+1)` in both halves.

**ECMP was never switched on.** Days defaults to `ShortestPath`, which picks the
same one of several equal-cost paths for every flow. The generated configs did
not set `routing`, so on a fat-tree eight flows shared one core link — a 6x
hotspot where the design intended 1.5x. This also invalidated an earlier
reading: "both flows chose s5 → s8 and switch 7 was unused" had been taken as
ECMP agreeing across the two simulators. It was `ShortestPath` being
deterministic; ECMP was not exercised at all.

**Synchronised flow starts made every arrival an N-way tie.** Identical rates
and identical start times put every flow's packets on the same instants, so each
arrival at a saturated buffer was decided by event ordering. Totals still
matched but the per-flow split drifted by 20 packets. Fixed by staggering starts
across one inter-arrival.

**Slowdown normalised per flow hid all queueing.** Everything read 1.0. The
offset is per hop and hop count varies per flow in a Clos or fat-tree, so it has
to be normalised per flow against the global minimum, not per flow against
itself.

**An undersized scaling workload gave the opposite answer.** §6.1.

**Debug code inside a P4 program was a third of the measured cost.** §4.3.

---

## 9. What this does not show

- **Uniform link rates only**, for the reason in §3.1.
- **Open loop only.** Closed-loop transport is compared against unmodified Days
  instead (§2).
- **One P4 program in the cross-simulator set** — a five-tuple exact-match table
  plus a TTL decrement, in two variants. Meters, hashes and stateful primitives
  beyond counting are untested against p4sim. A program that *reads*
  `queueing_metadata` is verified against Days' own scheduler
  (`p4-programs/queue_probe/`) but not against p4sim.
- **One worker in the agreement experiments.** ns-3's core is sequential, so
  that is the like-for-like comparison. **Whether the two still agree under
  multiple workers is not established** — that is a different experiment from
  §6, and given §7 it is where a real difference is most likely to appear.
- **Per-flow allocation above saturation** is not reproducible across the two,
  for the reason in §7.
- **One machine.** 31 GB and sixteen workers. Where a curve bends, and the k=32
  cap, are properties of the machine as much as of the design.
