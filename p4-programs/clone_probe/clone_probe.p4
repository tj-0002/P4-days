/* Probes the v1model primitives that CREATE packets: clone, recirculate and
 * multicast. Unlike register_read or mark_to_drop, these do not just touch
 * fields — they hand a new packet to the target's own runtime, which P4-Days
 * does not run (the pipelines are driven synchronously instead).
 *
 * The question is what happens: does the program still load, and do the
 * primitives silently do nothing, or do they break something?
 *
 * Purpose: P4-Days runs ingress in the P4Switch actor and egress in the Port
 * actor, after the Days scheduler's queue. Those are different threads sharing
 * one bm::Switch. Registers are the per-switch mutable state that both halves
 * can touch, so this is the program that actually stresses that sharing.
 * Every other P4 program to hand uses registers in ingress only.
 */
#include <core.p4>
#include <v1model.p4>

const bit<16> TYPE_IPV4 = 0x800;

header ethernet_t {
    bit<48> dstAddr;
    bit<48> srcAddr;
    bit<16> etherType;
}

header ipv4_t {
    bit<4>  version;
    bit<4>  ihl;
    bit<8>  diffserv;
    bit<16> totalLen;
    bit<16> identification;
    bit<3>  flags;
    bit<13> fragOffset;
    bit<8>  ttl;
    bit<8>  protocol;
    bit<16> hdrChecksum;
    bit<32> srcAddr;
    bit<32> dstAddr;
}

typedef bit<9> egressSpec_t;

struct metadata { }

struct headers {
    ethernet_t ethernet;
    ipv4_t     ipv4;
}

parser MyParser(packet_in packet, out headers hdr,
                inout metadata meta, inout standard_metadata_t standard_metadata) {
    state start { transition parse_ethernet; }
    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            TYPE_IPV4: parse_ipv4;
            default: accept;
        }
    }
    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition accept;
    }
}

control MyVerifyChecksum(inout headers hdr, inout metadata meta) { apply { } }

/* One array, touched from both pipelines, at the same index. */
register<bit<32>>(1024) shared_counters;

control MyIngress(inout headers hdr, inout metadata meta,
                  inout standard_metadata_t standard_metadata) {

    action forward(egressSpec_t port) {
        standard_metadata.egress_spec = port;
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
    }

    /* NOTE: a bare bm::Switch has none of simple_switch's primitives, so
     * mark_to_drop() is unavailable. v1model reserves 511 as the drop port,
     * so set it directly. See experiments/bmv2-threadsafety/README.md. */
    action drop() { standard_metadata.egress_spec = 9w511; }

    table ipv4_exact {
        key = { hdr.ipv4.dstAddr: exact; }
        actions = { forward; drop; NoAction; }
        size = 1024;
        default_action = drop();
    }

    apply {
        if (hdr.ipv4.isValid()) {
            bit<32> n;
            shared_counters.read(n, 32w0);
            shared_counters.write(32w0, n + 1);
            ipv4_exact.apply();

            /* packet-creating primitives */
            clone(CloneType.I2E, 32w5);                 // mirror to session 5
            standard_metadata.mcast_grp = 16w1;         // multicast group 1
        }
    }
}

control MyEgress(inout headers hdr, inout metadata meta,
                 inout standard_metadata_t standard_metadata) {
    apply {
        if (hdr.ipv4.isValid()) {
            /* same array, same index as ingress */
            bit<32> n;
            shared_counters.read(n, 32w0);
            shared_counters.write(32w0, n + 1);

            /* a second slot, written only here */
            bit<32> e;
            shared_counters.read(e, 32w1);
            shared_counters.write(32w1, e + 1);

            /* count how many times egress ran, including any clones */
            bit<32> c;
            shared_counters.read(c, 32w2);
            shared_counters.write(32w2, c + 1);
        }
    }
}

control MyComputeChecksum(inout headers hdr, inout metadata meta) { apply { } }

control MyDeparser(packet_out packet, in headers hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
    }
}

V1Switch(MyParser(), MyVerifyChecksum(), MyIngress(), MyEgress(),
         MyComputeChecksum(), MyDeparser()) main;
