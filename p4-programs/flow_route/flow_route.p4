/* Per-flow forwarding: the shape P4-Days needs to reproduce Days' own ECMP.
 *
 * Days picks one of the equal-cost paths per flow, by hashing (flow_id,
 * source_host, sink_host) with Rust's SipHash. A P4 program cannot recompute
 * that, so Days installs the answer instead: one entry per (flow, direction)
 * on each switch the flow crosses. The key is the five-tuple, and flow identity
 * rides in the port pair.
 *
 * This also parses TCP, which the earlier test programs did not — so it is the
 * first program that would notice a header claiming protocol 6 without a TCP
 * header behind it.
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

/* Source and destination port sit at the same offset in TCP and in UDP, so one
 * header extracts the flow identity from either. Which one a packet carries
 * depends on its Days flow type: a TCP flow gets a TCP header, everything else
 * gets UDP. */
header ports_t { bit<16> srcPort; bit<16> dstPort; }
/* The rest of a TCP header, extracted only when the protocol says TCP. */
header tcp_rest_t {
    bit<32> seqNo; bit<32> ackNo;
    bit<4> dataOffset; bit<4> res; bit<8> flags;
    bit<16> window; bit<16> checksum; bit<16> urgentPtr;
}

struct metadata { }
struct headers { ethernet_t ethernet; ipv4_t ipv4; ports_t ports; tcp_rest_t tcp_rest; }

parser MyParser(packet_in packet, out headers hdr, inout metadata meta,
                inout standard_metadata_t standard_metadata) {
    state start { transition parse_ethernet; }
    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            0x800: parse_ipv4;
            default: accept;
        }
    }
    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition select(hdr.ipv4.protocol) {
            6:  parse_ports;   /* TCP flows */
            17: parse_ports;   /* everything else */
            default: accept;
        }
    }
    state parse_ports {
        packet.extract(hdr.ports);
        transition select(hdr.ipv4.protocol) { 6: parse_tcp_rest; default: accept; }
    }
    state parse_tcp_rest { packet.extract(hdr.tcp_rest); transition accept; }
}

control MyVerifyChecksum(inout headers hdr, inout metadata meta) { apply { } }

/* counts what the pipeline saw, so a test can check it from outside */
register<bit<32>>(8) seen;

control MyIngress(inout headers hdr, inout metadata meta,
                  inout standard_metadata_t standard_metadata) {

    action forward(egressSpec_t port) {
        standard_metadata.egress_spec = port;
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
    }
    action drop() { standard_metadata.egress_spec = 9w511; }

    /* one entry per flow per direction, installed by Days from its own FIB */
    table flow_forward {
        key = {
            hdr.ipv4.srcAddr : exact;
            hdr.ipv4.dstAddr : exact;
            hdr.ports.srcPort  : exact;
            hdr.ports.dstPort  : exact;
        }
        actions = { forward; drop; NoAction; }
        size = 65536;
        default_action = drop();
    }

    apply {
        if (hdr.ipv4.isValid() && hdr.ports.isValid()) {
            bit<32> n;
            seen.read(n, 32w0);
            seen.write(32w0, n + 1);

            /* record the congestion bits so a test can prove they arrived.
             * Only a TCP flow has them: ECE and CWR live in the TCP flag byte,
             * and a UDP header has no equivalent. */
            if (hdr.tcp_rest.isValid() && (hdr.tcp_rest.flags & 8w0x40) != 0) {   /* ECE */
                bit<32> e; seen.read(e, 32w1); seen.write(32w1, e + 1);
            }
            if (hdr.tcp_rest.isValid() && (hdr.tcp_rest.flags & 8w0x80) != 0) {   /* CWR */
                bit<32> c; seen.read(c, 32w2); seen.write(32w2, c + 1);
            }
            flow_forward.apply();
        }
    }
}

control MyEgress(inout headers hdr, inout metadata meta,
                 inout standard_metadata_t standard_metadata) { apply { } }
control MyComputeChecksum(inout headers hdr, inout metadata meta) { apply { } }

control MyDeparser(packet_out packet, in headers hdr) {
    apply { packet.emit(hdr.ethernet); packet.emit(hdr.ipv4); packet.emit(hdr.ports); packet.emit(hdr.tcp_rest); }
}

V1Switch(MyParser(), MyVerifyChecksum(), MyIngress(), MyEgress(),
         MyComputeChecksum(), MyDeparser()) main;
