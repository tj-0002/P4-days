# Usage

Build it, run a P4 program on it, and reproduce the experiments.

---

## 0. Tested environment

Every number in [experiments.md](experiments.md) was produced with exactly
this. The BMv2 build in particular matters: its compile-time logging macros
account for about 72 % of what a P4 switch costs, so a different build gives a
different starting point.

| | version |
|---|---|
| OS | Ubuntu 24.04.3 LTS, kernel 7.0.0-31 |
| CPU / RAM | 20 logical cores, 31 GB (experiments use up to 16 workers) |
| Rust | rustc 1.98.1 (48a229cea 2026-09-01) |
| BMv2 | `2bdd0b7` (2025-10-22), i.e. `v1.15.0-88-g2bdd0b7` |
| p4c | 1.2.5.4 (SHA `17ade03c1`, Release) |
| ns-3 | 3.39 |
| p4sim | `dd69fd9` (2026-09-15) |

Two BMv2 installations of that same commit are used, one stock and one built
`--disable-logging-macros --disable-elogger`; §1.1 explains why and how.

---

## 1. Install

### 1.1 BMv2

P4-Days links `libbmv2`. Install
[behavioral-model](https://github.com/p4lang/behavioral-model) the normal way
first — this is the build that ns-3 + p4sim also uses, and the one a reader
already has.

**Build a second, logging-free copy for measurement.** As commonly installed,
`libbmv2` is compiled with `BM_LOG_DEBUG_ON` and `BM_ELOG_ON`, which cost about
**72 %** of what a P4 switch costs while printing nothing
([experiments.md §1](experiments.md#1-how-the-comparison-is-made-fair)). These
are compile-time macros, not a runtime level, so it is two installations:

```sh
cd behavioral-model
./configure --prefix=$HOME/bmv2-nolog \
            --disable-logging-macros --disable-elogger \
            'CFLAGS=-g -O2 -DFD_SETSIZE=4096 -U_FORTIFY_SOURCE' \
            'CXXFLAGS=-g -O2 -DFD_SETSIZE=4096 -U_FORTIFY_SOURCE'
make -j install
ln -sf /usr/local/lib/libthrift* $HOME/bmv2-nolog/lib/
```

Keep the `/usr/local` one: ns-3's p4sim links it, and the comparison needs both.

### 1.2 P4-Days

```sh
git clone <this repo> && cd p4-days/days

cargo build --release                                   # unmodified Days
cargo build --release --features p4                     # + the pure-Rust P4 layer
cargo build --release --features p4_bmv2                # + BMv2, against /usr/local

# the measurement build
BMV2_PREFIX=$HOME/bmv2-nolog \
  cargo build --release --features p4_bmv2 --target-dir target/bench-nolog
```

`BMV2_PREFIX` selects the installation at build time; no code changes.

**The three configurations are independent.** The default build contains no P4
code at all and needs no C++ toolchain — every upstream file the branch touches
is modified only inside `#[cfg]`. Verify with:

```sh
cargo test                        # 177 pass
cargo test --features p4          # 219
cargo test --features p4_bmv2     # 219
```

### 1.3 Compiling a P4 program

Standard `p4c`, v1model:

```sh
p4c --target bmv2 --arch v1model --std p4-16 -o . myprogram.p4
```

P4-Days loads the resulting `myprogram.json` — the same artefact BMv2 and
p4sim load.

---

## 2. Running a simulation

Add a `[p4]` section to a Days config. **Without it the simulation is
unmodified Days**, whatever the binary was built with.

```toml
seed = 1000
threading = "multiple"
num_threads = 8

[topology]
    category = "FatTree"
[topology.fat_tree]
    k = 4

[switch]
    port_rate = 1000000000
    capacity  = 1000
    discipline = "FIFO"        # FIFO or DRR only -- see below
    drop = "TailDrop"
    weights = [1]

[p4]
    switches = [20, 21, 22, 23]            # node ids; [] leaves the sim untouched
    program  = "p4-programs/forward/forward.json"
    table    = "MyIngress.flow_forward"    # where Days installs its routes
    action   = "MyIngress.forward"         # must take exactly one port argument
    log_events = false                     # per-packet CSV; off for measurement

[[flow_set]]
    flow_type = "PacketDistribution"
    flow_count = 16
    routing = "ECMP"
    [flow_set.traffic]
        initial_delay = 1.0
        duration = 200
        arr_dist = {type = "Uniform", low = 1, high = 1}
        pkt_size_dist = {type = "Uniform", low = 1042, high = 1042}
```

```sh
./target/release/days myconfig.toml
```

### 2.1 Every `[p4]` option

| key | default | what it does |
|---|---|---|
| `switches` | none | node ids that become P4 switches. Empty or absent leaves the simulation exactly as it was |
| `program` | none | a `p4c`-compiled JSON |
| `table` | none | the table Days installs its forwarding decisions into |
| `action` | none | that table's action; it must take one port argument |
| `allow_priority_rewrite` | `false` | let the program rewrite `priority`. Off because PFC reads it to pick a per-priority buffer, and a mid-path DSCP rewrite would break its flow control |
| `bmv2_trace_dir` | off | BMv2's own trace, one file per switch. Tens of lines per packet — for debugging a program's logic, not for measurement |
| `export_tables_dir` | off | write the installed routes in `simple_switch_CLI` syntax, so another implementation can be given the identical table |
| `export_registers_dir` | off | write each switch's register arrays at the end |
| `registers` | none | which arrays to write; both this and the directory must be set |
| `log_events` | `true` | one `p4_events.csv` row per packet per hop. **Set false to measure** — it costs 11–13 % |

### 2.2 Constraints you will hit

**Scheduling discipline must be FIFO or DRR.** `WRR` and `SP` clone packets on
enqueue, and a cloned packet cannot carry the live `bm::Packet` its pipeline
state lives in. The build asserts rather than corrupting silently.

**A P4 program cannot change the next hop.** Days computes the path — including
ECMP — and installs it as one exact entry per flow. The program looks it up.
Everything else is yours: rewrite headers, meter, count, mark, drop, read queue
state.

**`clone`, `recirculate` and `multicast` are refused at load**, because Days
does not run BMv2's replication engine and they would otherwise execute
silently and do nothing.

**One BMv2 instance per P4 switch, at about 10.5 MB.** 1,280 switches is
13.6 GB. Budget for it.

---

## 3. Writing a program for P4-Days

A v1model program runs from source without modification, within the feature set
of section 2.2. Four things about the environment are worth knowing before you
write one — the full mapping is
[architecture.md §4](architecture.md#4-the-mapping-from-days-values-to-header-fields).

**Flow identity is in the L4 port pair**, not in application ports. `flow_id`
occupies both 16-bit ports, high half in source. Matching on port 443 does
nothing meaningful; Days models no application layer.

**Parse the port pair protocol-agnostically.** A flow is TCP or UDP depending on
its Days `flow_type`, and the port pair sits at the same offset in both:

```p4
header ports_t { bit<16> srcPort; bit<16> dstPort; }

state parse_ipv4 {
    packet.extract(hdr.ipv4);
    transition select(hdr.ipv4.protocol) {
        6:  parse_ports;       // TCP
        17: parse_ports;       // UDP
        default: accept;
    }
}
```

A program that also needs TCP's flags extracts a second header after the ports,
**and must guard on it** — `hdr.tcp_rest.isValid()` — or it reads zeros on a UDP
flow. ECE and CWR exist only in a TCP header.

**Priority is IPv4 DSCP and ECN is IPv4 ECN.** There is no VLAN tag: it would
set the ethertype to `0x8100` and a stock program parsing Ethernet then IPv4
would fail to parse.

**`queueing_metadata` is real.** `deq_qdepth` and `deq_timedelta` carry the
queue the packet actually waited in, because egress runs from the scheduler's
dequeue path. `enq_qdepth` is set to the same depth rather than the depth at
enqueue time — the one field still approximate.

**Do not leave debug code in a program you are timing.** `log_msg` evaluates and
formats its arguments even when nothing is listening; a program calling it twice
per packet measured **9.09 µs a hop against 5.82 µs** without it.

`p4-programs/` has working examples: `forward/` (five-tuple forwarding),
`forward_verify/` (the same plus register counters), `queue_probe/` (reads queue
depth and wait).

---

## 4. Reproducing the experiments

### 4.1 The sixteen-scenario comparison

Needs ns-3 with the `p4sim` contrib module, plus `core`, `network`, `internet`,
`point-to-point` and `applications`.

```sh
cp -r days/artifact/ns3 <ns-3>/scratch/p4days
cd <ns-3> && ./ns3 build p4days-compare

cd p4-days/days/artifact
./run.sh                           # all sixteen: generate, run both, verify, time
ONLY=verify ./run.sh               # agreement only, about a minute
ONLY=time ./run.sh                 # timing only
./run.sh S8 S16                    # a subset
SMOKE=0.004 ONLY=verify ./run.sh   # fast shakeout, same shapes, fewer packets
```

Results land in `results/<scenario>/`, summarised in `results/summary.csv` and
`results/summary.md`. `analyze/verify.py` exits non-zero if the two runs differ.

**Days runs first, and that is not incidental**: it assigns port numbers, runs
the ECMP hash and exports both, and the ns-3 side reads what it produced rather
than being told the same network twice.

**`run.sh` rewrites `results/summary.csv` from scratch.** Running a subset
leaves only that subset in it. Merge before regenerating `summary.md`.

### 4.2 Multicore scaling

```sh
cd p4-days/experiments/multicore
./scale.sh                             # k = 8,16,32 x workers 1..16, ~45 min
KS=16 WORKERS=1,2,4 ./scale.sh         # a subset
REPS=5 ./scale.sh
python3 plot.py results/scaling.csv
```

Needs both measurement builds (`target/bench-nolog` and `target/bench-base`)
and about 14 GB of RAM at k=32.

`scaling.csv` separates `seconds` (the simulation, as Days reports it) from
`wall_s` (the whole process) and `setup_s` (the difference). **Use `seconds`.**
Set-up is serial and at k=32 it is 97.7 s against a 26.3 s simulation; folding
it in makes the speedup read 1.2x instead of 3.96x.

### 4.3 Correctness, equivalence, per-hop cost

```sh
cd p4-days/experiments
./correctness/run.sh                   # 18 checks, tests 1-5
./p4-equivalence/run.sh                # with vs without [p4], same topology
REPS=7 COUNTS="2000 10000 50000" ./overhead/bench.sh

cd ../days
P4D_PROFILE=1 ./target/bench-nolog/release/days <config>   # per-stage breakdown
```

`P4D_PROFILE=1` costs two clock reads per stage — about 0.3 µs of the ~10 µs
being measured, and it did not move the total (2.474 s on, 2.476 s off). Read
the shares, not the absolutes.

---

## 5. Troubleshooting

| symptom | cause |
|---|---|
| "sent N, received 0", no error | the P4 table is empty, so everything hits the default drop action. On the ns-3 side, check `--flowtables` has a **trailing slash** |
| packets vanish with no drop counted | a parse failure. Usually an IPv4 `protocol` that does not match the header actually present |
| "Device does not support SendFrom" | on the ns-3 side, use p4sim's `P4PointToPointHelper`; a P4 switch bridges its ports and the stock helper's `SupportsSendFrom()` is false |
| ns-3 queues ten times shallower than Days | `QueueBufferSize` is a **packet count** despite its name; the queue that fills is the device transmit queue, at ns-3's 100-packet default. Set `p2p.SetQueue(..., QueueSize(PACKETS, n))` |
| the switch, not the link, is the bottleneck | ns-3's `SwitchRate` defaults to 1000 pps. Set it far above the link rate |
| a per-hop cost around 9 µs instead of 1.5 µs | debug code in the P4 program, or the stock (logging-compiled) `libbmv2` |
| ECN or ECMP behaving oddly under load | the two simulators order same-timestamp events differently at a saturated buffer. [experiments.md §7](experiments.md#7-where-the-two-simulators-do-not-agree-and-why-neither-is-wrong) — check the signature in §7.5 before assuming a bug |
| ACKs or CNPs going the wrong way | reverse-direction synthesis. `addressing::is_reverse` must mirror how Days decides direction |
| an assert about the scheduling discipline | `WRR` and `SP` clone on enqueue; use FIFO or DRR with `[p4]` |
| a huge simulation is killed | one BMv2 instance per P4 switch at ~10.5 MB. Count your switches |

**A note on frame sizes.** Days' `pkt_size_dist` is **wire bytes**. If you are
comparing against something that specifies payload, add the headers: 1000 bytes
of UDP payload is 1000 + 8 + 20 + 14 = **1042**. Getting this wrong gives one
side a 4 % faster link, which is invisible at low load and catastrophic at
saturation.
