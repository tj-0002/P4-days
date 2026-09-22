/* Handoff section 10, Test 2 — header modification.
 *
 * Identical to Test 1 except that the pipeline now edits the packet: it
 * decrements TTL. Since Test 1 established that forwarding works, a failure
 * here points at the header round trip and nowhere else.
 *
 * The edit has to survive into the next hop, which is what proves the
 * synthesized bytes travel with the packet rather than being rebuilt.
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
        transition select(hdr.ethernet.etherType) { 0x800: parse_ipv4; default: accept; }
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

control MyIngress(inout headers hdr, inout metadata meta,
                  inout standard_metadata_t standard_metadata) {
    /* forwards without touching the packet */
    action forward(egressSpec_t port) {
        standard_metadata.egress_spec = port;
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;        /* the edit Test 2 checks */
        hdr.ipv4.diffserv = hdr.ipv4.diffserv;  /* left alone: Days owns priority */
    }
    action drop() { standard_metadata.egress_spec = 9w511; }

    table flow_forward {
        key = {
            hdr.ipv4.srcAddr : exact; hdr.ipv4.dstAddr : exact;
            hdr.ports.srcPort  : exact; hdr.ports.dstPort  : exact;
        }
        actions = { forward; drop; NoAction; }
        size = 65536;
        default_action = drop();
    }
    apply {
        if (hdr.ipv4.isValid() && hdr.ports.isValid()) {
            /* the TTL this switch received. Switch 1 sees the synthesized 64;
               switch 2 must see 63, which is only true if the first switch's
               edit travelled with the packet instead of being rebuilt. */
            log_msg("TTL_IN pkt={} ttl={}", {hdr.ports.dstPort, hdr.ipv4.ttl});
            flow_forward.apply();
            log_msg("TTL_OUT ttl={}", {hdr.ipv4.ttl});
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
