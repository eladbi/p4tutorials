/* -*- P4_16 -*- */
#include <core.p4>
#include <v1model.p4>

const bit<16> TYPE_IPV4 = 0x800;
const bit<8>  PROTOCOL_UDP = 0x11;

/*************************************************************************
*********************** H E A D E R S  ***********************************
*************************************************************************/

typedef bit<9>  egressSpec_t;
typedef bit<48> macAddr_t;
typedef bit<32> ip4Addr_t;
typedef bit<16> udpPort_t;

header ethernet_t {
    macAddr_t dstAddr;
    macAddr_t srcAddr;
    bit<16>   etherType;
}

header ipv4_t {
    bit<4>    version;
    bit<4>    ihl;
    bit<8>    diffserv;
    bit<16>   totalLen;
    bit<16>   identification;
    bit<3>    flags;
    bit<13>   fragOffset;
    bit<8>    ttl;
    bit<8>    protocol;
    bit<16>   hdrChecksum;
    ip4Addr_t srcAddr;
    ip4Addr_t dstAddr;
}

header udp_t {
    udpPort_t srcPort;
    udpPort_t dstPort;
    bit<16> len;
    bit<16> checksum;
}

header memcached_t {
    bit<96> command;
    bit<32> kesyStart;
    bit<8> lastDigit;
    bit<8> eol;
}

struct metadata {
    bit<8> digit;
}

struct headers {
    ethernet_t   ethernet;
    ipv4_t       ipv4;
    udp_t        udp;
    memcached_t memcached;
}

/*************************************************************************
*********************** P A R S E R  ***********************************
*************************************************************************/

parser MyParser(packet_in packet,
                out headers hdr,
                inout metadata meta,
                inout standard_metadata_t standard_metadata) {

    state start {
        transition parse_ethernet;
    }

    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            TYPE_IPV4: parse_ipv4;
            default: accept;
        }
    }

    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition select(hdr.ipv4.protocol) {
            PROTOCOL_UDP: parse_udp;
            default: accept;
        }
    }

    state parse_udp {
        packet.extract(hdr.udp);
        transition parse_memcached;
    }

    state parse_memcached {
        packet.extract(hdr.memcached);
        transition accept;
    }

}

/*************************************************************************
************   C H E C K S U M    V E R I F I C A T I O N   *************
*************************************************************************/

control MyVerifyChecksum(inout headers hdr, inout metadata meta) {
    apply {  }
}


/*************************************************************************
**************  I N G R E S S   P R O C E S S I N G   *******************
*************************************************************************/

control MyIngress(inout headers hdr,
                  inout metadata meta,
                  inout standard_metadata_t standard_metadata) {
    action drop() {
        mark_to_drop(standard_metadata);
    }

    action ipv4_forward(macAddr_t dstAddr, egressSpec_t port) {
        standard_metadata.egress_spec = port;
        hdr.ethernet.srcAddr = hdr.ethernet.dstAddr;
        hdr.ethernet.dstAddr = dstAddr;
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
        meta.digit = hdr.memcached.lastDigit;
    }

    action rewrite_ipv4_dst(ip4Addr_t dstAddr) {
        bit<32> original_dstAddr;

        // TODO: Complete here
        original_dstAddr = hdr.ipv4.dstAddr;
        hdr.ipv4.dstAddr = dstAddr;

        // TODO: Correct the UDP checksum. Use the following pseudo-code and adapt it to your implementation:
        hdr.udp.checksum = hdr.udp.checksum - (bit<16>)(dstAddr - original_dstAddr);
    }

    table ipv4_lpm {
        key = {
            hdr.ipv4.dstAddr: lpm;
        }
        actions = {
            ipv4_forward;
            drop;
            NoAction;
        }
        size = 1024;
        default_action = drop();
    }

    table set_nhop {
        key = {
            meta.digit: exact;
        }
        actions = {
            rewrite_ipv4_dst;
            drop;
            NoAction;
        }
        size = 1024;
    }

    // TODO: Add new tables here

    apply {
        // TODO: Need to apply other flow tables 111
        if (hdr.ipv4.isValid()) {
            ipv4_lpm.apply();
            set_nhop.apply();
        }
    }
}

/*************************************************************************
****************  E G R E S S   P R O C E S S I N G   *******************
*************************************************************************/

control MyEgress(inout headers hdr,
                 inout metadata meta,
                 inout standard_metadata_t standard_metadata) {
    action rewrite_mac(bit<48> smac) {
        hdr.ethernet.srcAddr = smac;
    }
    action drop() {
        mark_to_drop(standard_metadata);
    }
    table send_frame {
        key = {
            standard_metadata.egress_port: exact;
        }
        actions = {
            rewrite_mac;
            drop;
        }
        size = 256;
    }
    apply {
        send_frame.apply();
    }
}

/*************************************************************************
*************   C H E C K S U M    C O M P U T A T I O N   **************
*************************************************************************/

control MyComputeChecksum(inout headers  hdr, inout metadata meta) {
     apply {
	update_checksum(
	    hdr.ipv4.isValid(),
            { hdr.ipv4.version,
	      hdr.ipv4.ihl,
              hdr.ipv4.diffserv,
              hdr.ipv4.totalLen,
              hdr.ipv4.identification,
              hdr.ipv4.flags,
              hdr.ipv4.fragOffset,
              hdr.ipv4.ttl,
              hdr.ipv4.protocol,
              hdr.ipv4.srcAddr,
              hdr.ipv4.dstAddr },
            hdr.ipv4.hdrChecksum,
            HashAlgorithm.csum16);
    update_checksum(
	    hdr.udp.isValid(),
            { hdr.ipv4.srcAddr,
             hdr.ipv4.dstAddr,
             8w0,
             hdr.ipv4.protocol,
            hdr.udp.len,
            hdr.udp.srcPort,
            hdr.udp.dstPort,
            hdr.udp.len},
            hdr.udp.checksum,
            HashAlgorithm.csum16);
    }
}

/*************************************************************************
***********************  D E P A R S E R  *******************************
*************************************************************************/

control MyDeparser(packet_out packet, in headers hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
        packet.emit(hdr.udp);
        packet.emit(hdr.memcached);
        // TODO: Need to emit other headers
    }
}

/*************************************************************************
***********************  S W I T C H  *******************************
*************************************************************************/

V1Switch(
MyParser(),
MyVerifyChecksum(),
MyIngress(),
MyEgress(),
MyComputeChecksum(),
MyDeparser()
) main;
