# Architecture

How a C++ packet interpreter was put inside a Rust actor simulator. Each
section is a decision, recorded with the alternative that was available,
because the alternative is the first thing a reader asks about.

---

## 1. The constraint everything else follows from

**A Days packet carries no bytes.** `Packet` (`days/src/flows/packet.rs`) is:

```rust
pub struct Packet {
    pub time: f64,             // when it was sent on this hop
    pub creation_time: f64,
    pub size: usize,           // bytes, used only for transmission time
    pub packet_id: usize,
    pub flow_id: usize,
    pub queueing_delay: f64,
    pub priority: u8,          // 802.1Q PCP, 0-7
    pub last_packet: bool,
    pub ack: Option<TCPAck>,
    pub control: Option<ControlPacket>,   // e.g. DCQCN CNP
    pub ecn: EcnField,
    pub cwr: bool,
}
```

`size` exists to compute serialisation delay. There is no payload, no header,
no source or destination address — a packet does not know where it is going,
because the switch does. This is not an oversight: it is where Days' speed
comes from. What moves between actors is a hundred-odd bytes of plain data with
no allocation behind it.

Three consequences drive everything below.

1. **Bytes have to be manufactured** for BMv2, cheaply enough not to undo the
   reason Days is fast.
2. **What a program writes into a header has to survive to the next hop**, or
   nothing that accumulates along a path (INT, telemetry) can work. Days has
   nowhere to put it.
3. **The addresses do not exist** and must be derived. What a packet does have
   is `flow_id`, and the flow knows its endpoints.

## 2. Synthesize headers lazily, at the first P4 switch

**Chosen:** a packet gets bytes the first time it reaches a P4 switch, and
carries them from there on.

**Alternative:** synthesize at the source, so every packet always has bytes.

**Why:** a simulation with no P4 switches, or with P4 on a few switches of a
large fabric, pays nothing. The field is

```rust
#[cfg(feature = "p4")]
pub p4: Option<Box<crate::p4::payload::P4Payload>>,
```

so a packet that never meets a P4 switch costs one null pointer, and a build
without the feature costs not even that. Measured: compiling the integration in
and not using it costs **0.18 µs per packet-hop**, about 11 % over pure Days.

## 3. Days keeps owning routing

**Chosen:** Days computes the path, including its ECMP hash, and installs it
into the P4 table as one exact entry per flow. The program looks it up.

**Alternative:** let the program decide the next hop.

**Why:** Days' models, its statistics and its formally verified schedulers are
all built on a forwarding decision made before the run. A program that could
redirect a packet would invalidate them. **This is a real limitation and should
be read as one** — a P4 program in P4-Days cannot implement a routing protocol.
What it can do is everything else: rewrite headers, meter, count, mark, drop,
and read queue state.

`Topology::install_p4_program` (`days/src/topos/topo.rs`) walks the forwarding
information base Days already built (`fib`, and `r_fib` for the reverse
direction) and writes one exact entry per flow through `p4d_table_add_exact`.
Both directions are installed, because a TCP ACK travelling back has to match
too.

## 4. The mapping from Days values to header fields

Changing this invalidates every P4 program, every table entry and every
validation result produced under the old version. It therefore lives in exactly
one file (`days/src/p4/addressing.rs`), nothing else may hardcode a layout, and
the file carries a version string that is written into experiment output:

```rust
pub const MAPPING_VERSION: &str = "v2";
```

| Days value | Header field | Encoding |
|---|---|---|
| host id | IPv4 src/dst | `10.a.b.c`, host id in the low 24 bits |
| host id | Ethernet src/dst MAC | `00:00:` then the same 24 bits |
| `priority` (0–7) | IPv4 DSCP, upper 3 bits | class selector CS0–CS7 |
| `ecn` | IPv4 ECN, low 2 bits | the standard 2-bit encoding |
| `flow_id` | L4 source + destination port | 32 bits, high half in src |
| `flow_type` | IPv4 protocol | TCP flow → 6, everything else → 17 |
| `ack.ece`, `cwr` | TCP flags | ECE `0x40`, CWR `0x80` |
| `packet_id`, `flow_id` | BMv2 packet registers | not in any header |
| egress port | per-switch port table | not a global node id |

Four things here are load-bearing.

**Priority and ECN share the IPv4 TOS byte, and there is no VLAN tag.** Days'
`priority` is an 802.1Q PCP value, so 802.1Q is its obvious home — but a VLAN
tag sets the ethertype to `0x8100`, and a stock P4 program that parses Ethernet
then IPv4 would fail to parse. The point of the mapping is that unmodified
programs run, so DSCP it is. One byte write re-synchronises both values.

**`flow_id` uses both ports, not one.** `flow_id` comes from a global counter
and is not bounded by 16 bits. One port would silently alias two flows onto one
table entry — and since table entries are how Days' ECMP decision is expressed,
aliasing two flows would silently merge their paths. The pair gives 32 bits,
and an ECMP hash over the five-tuple sees both halves. A `debug_assert` catches
an id past 32 bits.

**Egress ports are per switch, not global node ids.** v1model's `egressSpec_t`
is 9 bits and 511 is reserved for drop, so a switch may expose at most 511
ports. A global node id would overflow on any large topology. `PortTable`
(`days/src/p4/ports.rs`) maps a switch's sorted, deduplicated neighbour list to
`0..n`, and back.

**Direction matters.** Packets carry no addresses, so a reverse-direction
packet (a TCP ACK, a DCQCN CNP) must have its endpoints swapped at synthesis.
Days decides direction from `ack`/`control` being set, and `addressing::is_reverse`
mirrors that exactly. Getting it wrong sends ACKs and CNPs the wrong way, and
congestion control silently stops working.

### 4.1 Which L4 header, and why the choice had to be made

**A Days packet has no protocol field.** It carries transport *behaviour* —
ACKs, congestion control, ECN echo — but never a wire format. The information
exists one level up, on the flow, as `flow_type`:

| `flow_type` | L4 | length | why |
|---|---|---|---|
| `TCP` | TCP (6) | 20 B | ECE and CWR live in the TCP flag byte and nowhere else |
| `PacketDistribution` | UDP (17) | 8 B | open loop, no congestion signalling to carry |
| `DCQCN` | UDP (17) | 8 B | signals with `control` (CNP) and `ecn`; RoCEv2 is UDP-encapsulated in reality too |

It is threaded `Flow.flow_type` → `FlowEndpoints.proto` →
`P4Payload::synthesize`, the only path by which it can reach the point where
bytes are made.

**Some L4 header is not optional**, whichever is chosen. The IPv4 header has to
declare a protocol, and a parser that follows the declaration will try to
extract that header — declaring 6 with no TCP bytes behind it makes the parse
fail and the packet vanish with nothing pointing at the cause. And flow
identity has to live where a table can match on it. The port pair sits at **the
same offset in TCP and UDP**, so one P4 header type extracts it from either:

```p4
header ports_t { bit<16> srcPort; bit<16> dstPort; }
...
transition select(hdr.ipv4.protocol) { 6: parse_ports; 17: parse_ports; }
```

A program that also needs TCP's flags extracts a second header after the ports,
only when the protocol says TCP.

> **This was v1's mistake.** The first version wrote `protocol = 6`
> unconditionally, because the requirement that produced a TCP header (ECE and
> CWR need somewhere to go) was recorded while the choice between TCP and UDP
> was not. It was invisible from inside: every flow type ran, tests passed, and
> the cross-simulator comparison agreed — but a `PacketDistribution` flow, the
> closest thing Days has to UDP, appeared to every P4 program as TCP, and no
> UDP experiment was possible at all. It surfaced only when the comparison was
> described precisely enough to notice the two simulators were sending
> different protocol numbers.

### 4.2 Five values come back

After the pipeline runs, five things are read out of the bytes and written into
the Days packet: `priority`, `ecn`, `cwr`, `size`, and the egress port.
Everything else the program changed stays in the bytes and travels onward
untouched.

`priority` is gated behind `[p4] allow_priority_rewrite`, default **false**.
PFC is the one part of Days that reads `packet.priority`, using it to select a
per-priority buffer; a pipeline rewriting DSCP mid-path would move packets
between PFC classes and break its flow control. A program that wants that must
say so.

**ECN ordering.** Days marks CE in its own AQM. If the pipeline ran on bytes
predating that marking, BMv2 would read a stale value and could overwrite the
fresh one. So Days' current `ecn` and `priority` are written into the bytes
immediately before the pipeline runs (`P4Payload::sync_fields`), not only at
synthesis.

## 5. Where the pipeline sits

```
host/source --> [P4Switch] --> [PortScheduler] --wire--> [P4Switch] --> ... --> sink
                    |                  |
              BMv2 ingress        BMv2 egress
                                  (P4EgressStage, on dequeue)
```

v1model puts a traffic manager *between* ingress and egress. In Days that
position belongs to the port scheduler, and the split follows it: `P4Switch`
runs the parser and the ingress pipeline, decides the egress port, and attaches
the live `bm::Packet` to `packet.p4.bm`; the scheduler's `P4EgressStage` hook
picks it up at **dequeue**, fills `queueing_metadata` from the queue it just
came out of, and runs egress and the deparser.

**So a program reads a real `deq_qdepth` and `deq_timedelta`.** Verified in
`p4-programs/queue_probe/`: on a congested switch the probe reports a max depth
of **999** against a capacity of 1000 and a mean wait of **8,127 µs**
(= 974 packets × 8.336 µs); on an uncongested switch in the same run, exactly
zero.

Two consequences travel with this.

**The BMv2 packet must survive the queue, and must never be aliased.**
`P4Payload`'s `Clone` is written by hand to *drop* it rather than copy it,
because two packets holding one `bm::Packet` is a use-after-free waiting to
happen. For the same reason `harvest_p4_switches` asserts against the `WRR` and
`SP` disciplines: they clone on enqueue, and a cloned packet's pipeline state
cannot survive. **With `[p4]`, use FIFO or DRR.**

**It costs 12 % to 55 %**, scaling with how long packets sit in queues — and
essentially none of that is running egress later. Measured and decomposed in
[experiments.md](experiments.md#5-what-real-queueing_metadata-costs).

### 5.1 Size accounting: four consumers that must disagree

A P4 egress pipeline can change a packet's length (INT appends headers). Four
things read `packet.size` and want different answers:

| consumer | wants |
|---|---|
| queue occupancy (`QueueState`) | the size while it was queued |
| serialisation delay | the size on the wire |
| throughput counters | the size on the wire |
| the packet handed to the next hop | the size on the wire |

So the egress hook has to run at dequeue **before** the scheduler computes
serialisation delay, and the new size must not be applied until occupancy
accounting is done. Rather than have every scheduler implement those four rules
identically, they live in one place (`days/src/p4/mod.rs`) and each scheduler
writes two lines:

```rust
p4_egress_begin!(self, packet, delay, depth);   // run egress, get the wire size
p4_egress_commit!(packet, wire);                // apply it after accounting
```

Both macros have two `#[cfg]` variants, so a build without the feature expands
them to nothing.

### 5.2 Two logs that join on one key

- `p4_events.csv` — one row per packet per hop: `time, switch_id, flow_id,
  packet_id, egress_node, outcome, size_in, size_out, priority, ecn,
  mapping_version`. What the *simulator* saw.
- BMv2's own trace, one file per switch, tagged with the same
  `(time, switch_id, flow_id, packet_id)`. What happened *inside the program*.

A suspicious row in the first leads straight to the matching lines in the
second. Both are off in a measurement run — they are per-packet writes on the
packet path and cost 11–13 %.

## 6. Build the topology normally, then harvest

**Chosen:** build the whole topology exactly as upstream Days does, then
`harvest_p4_switches()` removes the finished `PacketSwitch` for each designated
node and moves its `outputs`, `fib` and `r_fib` into a fresh `P4Switch`.

**Alternative:** branch at construction — if this node is a P4 switch, build a
`P4Switch`, else a `PacketSwitch`.

**Why:** the alternative touches `connect_neighbours` and five other call
sites, each a place Days' own wiring could be broken. Harvesting leaves the
wiring code untouched and the P4 switch inherits wiring that is known good by
construction.

The port table is built from the `outputs` map rather than from graph
adjacency, because `outputs` carries both neighbouring switches and any
attached host — delivering to a local sink is a port like any other.

## 7. Feature gating

```toml
p4      = []            # pure Rust: mapping, synthesis, port tables, the actor
p4_bmv2 = ["p4"]        # + the C++ dependency
```

Every upstream file this branch touches is modified only inside `#[cfg]`. The
C++ dependency is confined to `p4_bmv2`, which matters twice: the default build
stays pure Rust with no build-time C++ toolchain requirement, and the pure-Rust
`p4` layer is the part that would survive a future native reimplementation of
the pipeline. All three configurations build and test clean.

---

## 8. The BMv2 binding

### 8.1 Driving BMv2 synchronously

Stock BMv2 owns its own scheduling: `init_and_start()` spawns ingress and
egress threads, a transmit thread and a Thrift server. Days owns scheduling. So
the integration subclasses `bm::Switch` and leaves both pure virtuals empty:

```cpp
class DaysSwitch : public bm::Switch {
  DaysSwitch() : bm::Switch(false /* enable_swap */) { ... }
  int receive_(bm::port_t, const char *, int) override { return 0; }
  void start_and_return_() override {}           // no pipeline threads
};
```

The program is loaded with `init_objects()`, which reads the compiled JSON
without starting Thrift. Tables are filled through the shim's own C API rather
than `simple_switch_CLI`. The stages are fetched once at load (`get_parser`,
`get_pipeline("ingress")`, `get_pipeline("egress")`, `get_deparser`) and driven
directly, one packet at a time, from the Days actor.

**One subtlety that costs a day if missed:** a bare `bm::Switch` has none of the
v1model primitives — `register_read`, `mark_to_drop`, `hash` and the rest live
in the `simple_switch` target and register themselves through static
initialisation. Nothing references them by symbol, so the linker drops the
library unless told not to:

```
-Wl,--push-state,--no-as-needed -lsimpleswitch_runner -lsimpleswitch_thrift
-lthrift -lbmall -lgmp -lstdc++ -Wl,--pop-state
```

`init_and_start()` is never called, so linking the runner starts nothing.

### 8.2 The FFI boundary

`days/src/p4/bmv2/shim.h` / `shim.cc` is a C API over opaque handles. Every
rule exists because the other side is a multi-threaded Rust simulator:

- **No exception escapes.** Every entry point is wrapped in
  `try / catch(const std::exception&) / catch(...)` and returns a status code. A
  C++ exception crossing into Rust is undefined behaviour.
- **Errors are strings in thread-local storage**, retrieved by a separate call,
  so an error never needs allocating across the boundary.
- **Opaque handles**, so no BMv2 type appears in a Rust signature.
- **Match keys are arrays of fields**, one element per match field, not one
  concatenated buffer. Found the hard way: a 12-byte concatenated key for a
  4-field table returns `BAD_MATCH_KEY`, code 18.
- **All `unsafe` in the crate lives in `days/src/p4/bmv2/mod.rs`**, the safe
  wrapper.

### 8.3 Thread safety, settled by experiment

Days runs many workers. BMv2's own thread-safety story is about *its* threads,
which are not running here. The narrower question — can two Days workers each
drive their own `bm::Switch` at once? — decides whether the integration can
exist at all, so it was measured rather than read
(`experiments/bmv2-threadsafety/`).

```
stage 1  sequential     4 switches x 1000 packets, one thread    reference output
stage 2  parallel       4 switches x 1000 packets, 4 threads     one switch per thread
stage 3  equivalence    parallel vs sequential                   0 mismatches / 4000
stage 4  race detection ThreadSanitizer and Helgrind
```

**Verdict: safe, with one requirement.**

| Helgrind run | data races |
|---|---|
| without startup warmup (control) | **5** |
| with startup warmup | **0** |

Every race traced to one place: libbmv2's lazily-initialised global
`EventLogger`, reached from the parser on the very first packet. So
`bm::EventLogger::get()` is called once at startup under `std::call_once`,
before any worker touches a switch. Stage 3 is what makes the verdict mean
something — the parallel run is byte-identical to the sequential one, egress
port and a digest of the deparsed frame, for all 4,000 packets.

`BmSwitch` is therefore `Send` but deliberately **not** `Sync`: a switch may
move between workers, but two workers may never hold one at the same time —
exactly the guarantee nexosim gives for a model. Sharing a switch between an
ingress actor and its port schedulers needs an explicit
`Arc<Mutex<Option<BmSwitch>>>`, and contention is per switch.

**The measured consequence is that no global serialisation was introduced.** On
a 1,280-switch fat-tree, P4-Days reaches 5.19x on sixteen workers where
unmodified Days reaches 3.96x, and the ratio of the two costs *falls* as
workers are added. A mutex around the engine would make it rise.

### 8.4 Can a switch → scheduler → same switch cycle deadlock?

The split creates a cycle in the actor graph, so it was checked before being
built (`experiments/pipeline-split/`, `tests/spike_mailbox_cycle.rs`).

**Only if the scheduler forwards synchronously. Days' schedulers do not.**

| scheduler behaviour | result |
|---|---|
| forwards inside `packet_received` (`send().await`) | **deadlock**, at mailbox capacity 1 and 64 alike |
| enqueues, forwards from a scheduled departure event | **no deadlock** |

The failing shape reports itself rather than hanging, which is worth knowing:

```
ExecutionError(Deadlock([
  DeadlockInfo { model: ["Switch"],    mailbox_size: 1 },
  DeadlockInfo { model: ["Scheduler"], mailbox_size: 1 }]))
```

The safe shape is what `days/src/schedulers/port.rs` already does.

### 8.5 Primitives that are refused, not ignored

`clone`, `recirculate` and `multicast` execute without error under a bare
`bm::Switch` and **do nothing**, because Days does not run BMv2's replication
engine — packet duplication in Days is the simulator's job, not the pipeline's.
Silently doing nothing is the worst available behaviour, so the loader scans the
compiled JSON and refuses to start a program that uses them.

---

## 9. What holds by construction

These need no experiment; they are readable from the code.

- **A P4 program cannot change the next hop** (§3).
- **`clone`, `recirculate`, `multicast` are refused at load** (§8.5).
- **`queueing_metadata` is real**, from the dequeue path (§5). `enq_qdepth` is
  set to the same depth rather than the depth at enqueue time — the one field
  still approximate.
- **Port numbers are per switch and capped at 511** by v1model's 9-bit
  `egressSpec_t` (§4).
- **L4 ports carry `flow_id`, not application ports** (§4).
- **Which L4 header a flow gets is fixed by its type**, not chosen per packet
  (§4.1). A packet carries no protocol field, so nothing finer is possible
  without inventing one.

  | | TCP | UDP |
  |---|---|---|
  | P4-Days | real TCP header, program can read the flags | real UDP header |
  | Days (unmodified) | TCP *behaviour*, no header anywhere | no notion of UDP at all |
  | ns-3 + p4sim | real TCP | real UDP |

  The middle row is worth stating carefully. Unmodified Days has no protocol
  concept: `TCP` is a flow type that models acknowledgements and congestion
  control, `PacketDistribution` is a distribution-driven source with no
  feedback loop. Days never calls it UDP and there is no header in which the
  difference could appear. **"UDP" only becomes a real thing at the P4-Days
  boundary**, where a header is manufactured. Writing "Days supports UDP"
  invites the question "where?", and there is no answer.

- **A program needing TCP's flags must guard on them.** ECE and CWR exist only
  in a TCP header, so a program reading them has to check
  `hdr.tcp_rest.isValid()` or it reads zeros on a UDP flow.
