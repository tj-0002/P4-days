# P4-Days

[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.22936768.svg)](https://doi.org/10.5281/zenodo.22936768)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](LICENSE)

**Run a real P4 pipeline inside a multicore network simulator.**

P4-Days puts [BMv2](https://github.com/p4lang/behavioral-model) — the P4
reference software switch — inside
[Days](https://github.com/iQua/days), a discrete-event network simulator
written in Rust whose event core runs on many cores. A switch in a Days
simulation can then forward packets according to a compiled P4 program, while
Days keeps owning time, links, queueing, scheduling and parallel execution.

Against the established ns-3 integration it is **1.9x to 2.3x faster on one
core**. ns-3's event core is sequential; Days' is not, and the pipeline work
parallelises with it: on a 1,280-switch fat-tree, **5.19x on sixteen workers**
against unmodified Days' 3.96x.

> 📄 **Paper:** [`paper/P4-Days.pdf`](paper/P4-Days.pdf) ·
> [doi.org/10.5281/zenodo.22936768](https://doi.org/10.5281/zenodo.22936768)
> — a preprint, not yet peer reviewed. Every number in it can be re-derived
> from this repository; [`paper/README.md`](paper/README.md) maps each table to
> the file that produced it.

---

## Why

Simulating a P4 data plane means interpreting a P4 program once per packet per
hop, which is expensive — a few microseconds a hop, against a few hundred
nanoseconds for a conventional simulated switch. A datacenter experiment is
hundreds of millions of packet-hops, so the interpreter is the whole cost and
the simulator around it decides how long the experiment takes.

**[p4sim](https://github.com/HuiZhang-Rex/p4sim) is the established way to do
this**: an ns-3 module that makes each ns-3 switch a `bm::Switch`, copies each
ns-3 packet into a BMv2 buffer, runs the pipeline, and reads the egress port
back out of the PHV. It is the right design and it works. But **ns-3's event
core is sequential**, so the cost of the pipeline lands on one core and there
is no way to add more.

**Days' event core is not sequential.** It models network components as actors
on the [nexosim](https://github.com/asynchronics/nexosim) runtime and executes
independent events on many workers. Executing a P4 pipeline is per-switch CPU
work with no state shared between switches — which is exactly the shape that
parallelises. So the question this project asks is:

> Can a P4 pipeline be embedded in a parallel discrete-event simulator without
> breaking either the pipeline's semantics or the simulator's parallelism?

The answer is yes, and the parallelism turns out to *improve*: because the
pipeline spreads better than the event scheduling already there, adding cores
makes P4-Days' cost over unmodified Days go **down**, not up.

## Why it is not obvious

The two halves disagree about what a packet is.

| | Days | BMv2 |
|---|---|---|
| a packet is | a struct: size, ids, priority, ECN, timestamps | a byte buffer plus a PHV |
| forwarding | decided once, before the run | computed per packet by a program |
| concurrency | many workers over an actor graph | one switch, its own threads |
| per-hop state | none carried in the packet | headers the program wrote |

**A Days packet carries no bytes**, and that is deliberate: it is how Days is
fast. A P4 program cannot run on something with no bytes, and giving Days real
bytes everywhere would change every model it has. The integration is the set of
decisions that resolve this without doing either —
[docs/architecture.md](docs/architecture.md) is those decisions.

## What it does

- **A v1model P4 program runs from source without modification**, within the
  feature set below: `.p4` compiled by `p4c` to v1model JSON, loaded with BMv2's
  own `init_objects()`. Programs using `clone`, `recirculate` or `multicast` are
  refused at load rather than silently doing nothing.
- **Days keeps the network model.** Links, propagation, queueing disciplines
  (FIFO, DRR, …), AQM (TailDrop, RED), ECN, PFC, TCP and DCQCN are Days'.
- **P4 is opt-in and costs nothing when off.** Two cargo features (`p4` for the
  pure-Rust layer, `p4_bmv2` for the C++ dependency); a build without them is
  unmodified Days, and a packet that never meets a P4 switch costs one null
  pointer.
- **The pipeline is split where v1model says it is.** Ingress runs at the
  switch; the traffic manager's position belongs to Days' port scheduler, so
  egress runs at **dequeue** and a program reads a real `deq_qdepth` and
  `deq_timedelta`.

## Quick start

**Prerequisites.** A Rust toolchain, and [BMv2](https://github.com/p4lang/behavioral-model)
installed (`libbmv2` plus the `simple_switch` target). P4-Days links it; it does
not vendor it.

```sh
git clone --recurse-submodules https://github.com/tj-0002/P4-days
cd P4-days/days
cargo build --release --features p4_bmv2
```

Run a two-switch network in which both switches forward according to a compiled
P4 program:

```sh
./target/release/days ../experiments/correctness/configs/test3.toml
```

```
Activated 2 P4 switches with 8 forwarding entries.
Total packets processed: 20
Elapsed wall-clock time: 0.003 seconds.
```

The interesting output is `logs/correctness/test3/p4_events.csv`, one row per
packet per programmable hop — this is the pipeline actually running, not a
model of it:

```
time,switch_id,flow_id,packet_id,egress_node,outcome,size_in,size_out,priority,ecn,mapping_version
1.01,1,0,0,2,forward,1000,1000,0,NotEct,v2
1.02,2,0,0,3,forward,1000,1000,0,NotEct,v2
1.505,1,1,0,2,forward,500,500,0,NotEct,v2
```

Two flows run between the same pair of hosts, so the table has to tell them
apart — which is what per-flow forwarding, and therefore Days' ECMP, depends on.

**Turning P4 on is one config section.** `test3.toml` differs from an ordinary
Days config only by this:

```toml
[p4]
    switches = [1, 2]                                    # node ids
    program  = "../p4-programs/flow_route/flow_route.json"   # p4c output
    table    = "MyIngress.flow_forward"                  # Days installs its routes here
    action   = "MyIngress.forward"                       # must take one port argument
```

Delete the section and the same file is an ordinary Days simulation. Build
without `--features p4_bmv2` and there is no P4 code in the binary at all, and
no C++ toolchain is needed.

**Next:** [`docs/usage.md`](docs/usage.md) covers every `[p4]` option, writing a
program for this environment, the constraints to know about, and reproducing
the paper's experiments.

## Results

Measured against ns-3 + p4sim across sixteen scenarios — four datacenter
topologies (single bottleneck, leaf-spine, three-tier Clos, fat-tree k=4), two
traffic patterns, two offered loads. Both simulators are generated from one
file, and both link the same BMv2 build, because comparing a logging-free BMv2
against a stock one measures build configuration rather than integration.

**They do the same thing.** Register arrays identical in **11 of 16**
scenarios; total pipeline invocations identical in **15 of 16** (the sixteenth
differs by 1.30 %, in ns-3's favour); per-packet delay within one packet
serialisation time of a constant per-hop offset. The five that differ are all
above persistent saturation, where the two order same-timestamp events
differently — a question neither simulator's model defines, and not something
the integration introduced: unmodified Days reproduces P4-Days byte for byte in
exactly those scenarios.

**It is faster.**

| BMv2 build on both sides | range | median |
|---|---|---|
| stock, as commonly installed | 1.82x – 1.97x | **1.90x** |
| `--disable-logging-macros --disable-elogger` | 1.94x – 2.52x | **2.30x** |

**And it still scales.** Speedup against the same variant at one worker:

| | 1 | 2 | 4 | 8 | 16 |
|---|---:|---:|---:|---:|---:|
| unmodified Days, k=32 | 1.00x | 1.77x | 2.57x | 3.32x | 3.96x |
| **P4-Days, k=32** | 1.00x | 1.91x | 3.23x | 4.28x | **5.19x** |

Full tables, method and interpretation: [docs/experiments.md](docs/experiments.md).

## Limits worth knowing before you start

- **One BMv2 instance per simulated switch**, at about **10.5 MB** each. A
  k=32 fat-tree is 1,280 switches and 13.6 GB; k=64 would be roughly 54 GB.
  This is a memory ceiling, not a time one.
- **A P4 program cannot change the next hop.** Days computes the path and
  installs it as table entries; the program looks it up. Routing stays Days'.
- **`clone`, `recirculate` and `multicast` are refused at load**, because Days
  does not run BMv2's replication engine and they would otherwise execute
  silently and do nothing.
- **Uniform link rates**, because Days charges one `port_rate` to every port.
- **L4 ports carry `flow_id`**, not application ports, so a program matching on
  port 443 does nothing meaningful.

## Documentation

| | |
|---|---|
| [paper/P4-Days.pdf](paper/P4-Days.pdf) | the paper, and its LaTeX source |
| [docs/architecture.md](docs/architecture.md) | how BMv2 was put inside Days, and the alternative at each decision |
| [docs/experiments.md](docs/experiments.md) | what was measured, how, the results, and what they do and do not show |
| [docs/usage.md](docs/usage.md) | build it, configure it, write a program for it, reproduce the experiments |

## Layout

```
paper/                the paper
days/                 submodule: a fork of iQua/days. This work is src/p4/
  artifact/           the sixteen-scenario reproduction package
docs/                 the three documents above
experiments/          overhead, multicore scaling, and the two design spikes
p4-programs/          P4 programs used by the experiments and tests
```

## Status and licence

Research code accompanying the P4-Days paper. **P4-Days is a P4 extension of
[Days](https://github.com/iQua/days)**, a simulator built by the
[iQua lab](https://iqua.ece.toronto.edu/) at the University of Toronto. This
work is `src/p4/` and `artifact/` on a fork, which the `days/` submodule pins at
one commit. The nine upstream files it touches are modified only inside
`#[cfg]`, so a default build contains no P4 code and follows the original Days
execution path.

Not an official iQua project. Days is AGPL-3.0 and so is this, except the
manuscript under `paper/`, which is copyright the author. See `LICENSE` and
`NOTICE`.

```sh
git clone --recurse-submodules https://github.com/tj-0002/P4-days
# already cloned without it:
git submodule update --init
```
