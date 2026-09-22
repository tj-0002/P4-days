/* m4_compare.p4 with its per-packet debugging removed: no register counter and
 * no log_msg. Both were there to show which entry a packet matched while the
 * two simulators were being lined up, and both run on every packet, so a cost
 * measurement taken with them in place is partly a measurement of them. */
/* The program both simulators run for milestone M4.
 *
 * Identical to flow_route.p4 except that it reads the port pair from either a
 * TCP or a UDP header. The two sides disagree on the transport: P4-Days marks
 * its synthesized headers as TCP, because that is where it keeps the congestion
 * bits Days already tracks, while the ns-3 side sends real UDP from a socket
 * whose source port we bind. Both carry the same ports in the same place, so
 * the table keys on those and not on the protocol number.
 *
 * That is a deliberate narrowing of the comparison: it asks whether the
 * pipeline forwards the same way given the same addresses and ports, which is
 * the claim milestone M4 makes, and not whether the two produce byte-identical
 * frames, which they cannot while one of them is synthesizing headers.
 */
#include <core.p4>
#include <v1model.p4>

typedef bit<9> egressSpec_t;

header ethernet_t { bit<48> dstAddr; bit<48> srcAddr; bit<16> etherType; }

header ipv4_t {
    bit<4> version; bit<4> ihl; bit<8> diffserv; bit<16> totalLen;
    bit<16> identification; bit<3> flags; bit<13> fragOffset;
    bit<8> ttl; bit<8> protocol; bit<16> hdrChecksum;
    bit<32> srcAddr; bit<32> dstAddr;
}

/* the first four bytes of TCP and of UDP alike */
header ports_t { bit<16> srcPort; bit<16> dstPort; }

struct metadata { }
struct headers { ethernet_t ethernet; ipv4_t ipv4; ports_t ports; }

parser MyParser(packet_in packet, out headers hdr, inout metadata meta,
                inout standard_metadata_t standard_metadata) {
    state start { transition parse_ethernet; }
    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) { 0x800: parse_ipv4; default: accept; }
    }
    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition select(hdr.ipv4.protocol) {
            6:  parse_ports;   /* TCP  — what P4-Days synthesizes */
            17: parse_ports;   /* UDP  — what the ns-3 side sends */
            default: accept;
        }
    }
    state parse_ports { packet.extract(hdr.ports); transition accept; }
}

control MyVerifyChecksum(inout headers hdr, inout metadata meta) { apply { } }

/* [0] packets seen, [1] table hits, [2] table misses */
register<bit<32>>(8) seen;

control MyIngress(inout headers hdr, inout metadata meta,
                  inout standard_metadata_t standard_metadata) {

    action forward(egressSpec_t port) {
        standard_metadata.egress_spec = port;
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
    }
    action drop() { standard_metadata.egress_spec = 9w511; }

    table flow_forward {
        key = {
            hdr.ipv4.srcAddr : exact;
            hdr.ipv4.dstAddr : exact;
            hdr.ports.srcPort : exact;
            hdr.ports.dstPort : exact;
        }
        actions = { forward; drop; NoAction; }
        size = 65536;
        default_action = drop();
    }

    apply {
        if (hdr.ipv4.isValid() && hdr.ports.isValid()) {
            flow_forward.apply();
        }
    }
}

control MyEgress(inout headers hdr, inout metadata meta,
                 inout standard_metadata_t standard_metadata) { apply { } }
control MyComputeChecksum(inout headers hdr, inout metadata meta) { apply { } }
control MyDeparser(packet_out packet, in headers hdr) {
    apply { packet.emit(hdr.ethernet); packet.emit(hdr.ipv4); packet.emit(hdr.ports); }
}

V1Switch(MyParser(), MyVerifyChecksum(), MyIngress(), MyEgress(),
         MyComputeChecksum(), MyDeparser()) main;
