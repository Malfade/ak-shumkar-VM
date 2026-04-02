// SPDX-FileCopyrightText: 2026 Greenbone AG
// SPDX-License-Identifier: GPL-2.0-or-later

//! UDP port scanner with three-phase hybrid approach:
//!
//! 1. **Fast sweep** — raw UDP probes + pcap ICMP capture to quickly identify closed ports
//! 2. **Service probes** — protocol-specific payloads for ports that did not respond
//! 3. **Adaptive retry** — RTT-adaptive timeouts, ICMP rate-limit detection, exponential backoff

use futures::StreamExt;
use nasl_function_proc_macro::nasl_function;
use pnet::packet::{
    Packet,
    icmp::{IcmpPacket, IcmpTypes, destination_unreachable::IcmpCodes},
    icmpv6::{Icmpv6Packet, Icmpv6Types},
    ip::IpNextHeaderProtocols,
    ipv4::Ipv4Packet,
    ipv6::Ipv6Packet,
};
use pcap::{Active, Capture, Inactive, PacketCodec, PacketStream};
use std::{
    collections::{BTreeSet, HashMap},
    net::{IpAddr, SocketAddr, UdpSocket},
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::{
    sync::mpsc::{self, Receiver, Sender},
    sync::Mutex,
    time::sleep,
};
use tracing::{debug, warn};

use super::SynScanError;
use crate::function_set;
use crate::nasl::builtin::network::network::scanner_add_port_shared;
use crate::nasl::builtin::network::Port;
use crate::nasl::prelude::*;
use crate::nasl::utils::function::utils::DEFAULT_TIMEOUT;
use crate::storage::items::kb::{Host, KbItem, KbKey, UdpScanner};

// ─── Constants ───────────────────────────────────────────────────────────────

/// Layer 2 frame offset for Ethernet frames captured by pcap
const L2_FRAME_OFFSET: usize = 16;
const MIN_ALLOWED_PACKET_LEN: usize = 16;
const BITS_PER_WORD: usize = 32;
const BITS_PER_BYTE: usize = 8;

/// Detect ICMP rate limiting by observing that inter-ICMP intervals are large.
/// Windows sends at most 1 ICMP/sec; Linux sends ~1000/sec.
/// We collect a minimum number of inter-arrival intervals before deciding.
const ICMP_RATE_LIMIT_MIN_SAMPLES: usize = 5;
/// If the median inter-ICMP interval is above this value, the target is rate-limiting.
/// 500 ms comfortably separates Windows (1/s, ~1000 ms apart) from
/// Linux (1000/s, ~1 ms apart) while tolerating light packet loss.
const ICMP_RATE_LIMIT_INTERVAL_THRESHOLD: Duration = Duration::from_millis(500);

/// nmap-style strategy: always send probes as fast as possible (burst),
/// then wait for ICMP responses. On rate-limited hosts we just wait longer.
/// Never throttle the send side.

/// Default post-send wait with no RTT data and no rate limiting.
const POST_SEND_WAIT_DEFAULT: Duration = Duration::from_millis(500);

/// Minimum post-send wait (fast LAN hosts).
const POST_SEND_WAIT_MIN: Duration = Duration::from_millis(50);

/// Multiplier applied to (mean + 3σ) RTT.
const POST_SEND_RTT_MULTIPLIER: f64 = 2.0;

/// On a rate-limited host the ICMP answers trickle in at ~1/sec.
/// For N unresolved ports we wait up to N * 1.1 sec + margin.
/// This per-port coefficient is used to compute the total wait.
const RATE_LIMITED_WAIT_PER_PORT: Duration = Duration::from_millis(1100);
/// Safety cap so we don't wait forever on huge port lists.
const RATE_LIMITED_WAIT_MAX: Duration = Duration::from_secs(120);
/// Hard cap for UDP scan runtime per host to keep scans predictable.
/// Remaining unresolved ports are marked as filtered once this budget is reached.
const MAX_UDP_SCAN_RUNTIME: Duration = Duration::from_secs(660);

/// Maximum scan passes. Pass 1: full sweep. Pass 2+: retry unresolved.
const MAX_PASSES: usize = 3;

/// Default per-port timeout when no RTT data available (used in estimated_timeout).
#[cfg(test)]
const DEFAULT_PORT_TIMEOUT: Duration = Duration::from_secs(2);

/// Small inter-probe delay to avoid kernel buffer overflow on burst sends.
const INTER_PROBE_DELAY: Duration = Duration::from_micros(100);

/// If RTT mean < this, target is on fast LAN — shorter waits, fewer passes.
const FAST_HOST_RTT_THRESHOLD: Duration = Duration::from_millis(5);

/// Maximum number of UDP ports to scan (nmap top-N).
/// The full IANA list has ~5000 ports; scanning all of them is wasteful.
/// nmap scans top 100 by default. We use 100 for a reasonable balance.
const MAX_UDP_PORTS: usize = 100;

/// nmap's top 100 UDP ports, ordered by frequency.
const TOP_UDP_PORTS: [u16; 100] = [
    53, 67, 123, 135, 137, 138, 161, 162, 445, 631,
    1434, 1900, 4500, 5353, 49152, 49154, 111, 69, 500, 514,
    49153, 1701, 520, 49155, 49156, 49157, 1645, 1646, 1812, 1813,
    5060, 5000, 2049, 427, 3283, 49158, 49159, 49160, 9200, 623,
    626, 1025, 177, 5632, 10000, 17185, 1026, 1027, 1028, 1029,
    1030, 1022, 1023, 5355, 32768, 32769, 32771, 32815, 2222, 593,
    518, 4444, 636, 49161, 49163, 49165, 49167, 49175, 49176, 120,
    3456, 20031, 30718, 31337, 33281, 158, 3703, 10080, 136, 139,
    68, 80, 88, 443, 515, 520, 997, 996, 998, 999,
    1718, 1719, 2223, 3288, 5002, 7007, 33434, 49186, 49190, 65024,
];

// ─── UDP Payload Database ─────────────────────────────────────────────────────
//
// Protocol-specific probes per well-known UDP port.
// Format: (port, payload_bytes)
// Sources: nmap-payloads, RFC specs

fn get_probe_for_port(port: u16) -> Option<&'static [u8]> {
    match port {
        // DNS — standard query for "version.bind" TXT IN
        53 => Some(&[
            0xab, 0xcd, // transaction ID
            0x01, 0x00, // standard query, recursion desired
            0x00, 0x01, // 1 question
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // no answers/authority/additional
            0x07, 0x76, 0x65, 0x72, 0x73, 0x69, 0x6f, 0x6e, // "version"
            0x04, 0x62, 0x69, 0x6e, 0x64, // "bind"
            0x00, // root label
            0x00, 0x10, // QTYPE: TXT
            0x00, 0x03, // QCLASS: CHAOS
        ]),
        // NTP — NTP v2 client request (mode 3)
        123 => Some(&[
            0x1b, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]),
        // SNMP v1 — GetRequest for sysDescr.0 (community "public")
        161 => Some(&[
            0x30, 0x26, // SEQUENCE
            0x02, 0x01, 0x00, // version: 0 (SNMPv1)
            0x04, 0x06, 0x70, 0x75, 0x62, 0x6c, 0x69, 0x63, // community: "public"
            0xa0, 0x19, // GetRequest PDU
            0x02, 0x01, 0x01, // request-id: 1
            0x02, 0x01, 0x00, // error-status: 0
            0x02, 0x01, 0x00, // error-index: 0
            0x30, 0x0e, // variable bindings
            0x30, 0x0c, 0x06, 0x08, 0x2b, 0x06, 0x01, 0x02, 0x01, 0x01, 0x01, 0x00,
            0x05, 0x00,
        ]),
        // TFTP — RRQ for "test" in netascii
        69 => Some(&[
            0x00, 0x01, // opcode: RRQ
            0x74, 0x65, 0x73, 0x74, 0x00, // filename: "test"
            0x6e, 0x65, 0x74, 0x61, 0x73, 0x63, 0x69, 0x69, 0x00, // mode: "netascii"
        ]),
        // NetBIOS Name Service — general query
        137 => Some(&[
            0xab, 0xcd, // transaction ID
            0x01, 0x10, // flags: broadcast, recursion desired
            0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x20, // encoded name length (32)
            0x43, 0x4b, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
            0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
            0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
            0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
            0x00, // end of name
            0x00, 0x21, // QTYPE: NBSTAT
            0x00, 0x01, // QCLASS: IN
        ]),
        // SSDP — M-SEARCH for all services
        1900 => Some(
            b"M-SEARCH * HTTP/1.1\r\nHOST:239.255.255.250:1900\r\nMAN:\"ssdp:discover\"\r\nMX:1\r\nST:ssdp:all\r\n\r\n",
        ),
        // mDNS — query for local services
        5353 => Some(&[
            0x00, 0x00, // transaction ID: 0 (mDNS)
            0x00, 0x00, // standard query
            0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x05, 0x5f, 0x68, 0x74, 0x74, 0x70, // "_http"
            0x04, 0x5f, 0x74, 0x63, 0x70, // "_tcp"
            0x05, 0x6c, 0x6f, 0x63, 0x61, 0x6c, 0x00, // "local"
            0x00, 0x0c, // QTYPE: PTR
            0x00, 0x01, // QCLASS: IN
        ]),
        // SIP OPTIONS — service discovery
        5060 => Some(
            b"OPTIONS sip:nm SIP/2.0\r\nVia: SIP/2.0/UDP nm;branch=foo\r\nFrom: <sip:nm@nm>;tag=root\r\nTo: <sip:nm2@nm2>\r\nCall-ID: 50000\r\nCSeq: 42 OPTIONS\r\nMax-Forwards: 70\r\nContent-Length: 0\r\nContact: <sip:nm@nm>\r\nAccept: application/sdp\r\n\r\n",
        ),
        // RPC portmapper — DUMP call
        111 => Some(&[
            0x72, 0xfe, 0x1d, 0x13, // XID
            0x00, 0x00, 0x00, 0x00, // call
            0x00, 0x00, 0x00, 0x02, // RPC version 2
            0x00, 0x01, 0x86, 0xa0, // program: portmapper (100000)
            0x00, 0x00, 0x00, 0x02, // version 2
            0x00, 0x00, 0x00, 0x04, // procedure: DUMP
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // null credentials
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // null verifier
        ]),
        // DHCP — DISCOVER
        67 => Some(&[
            0x01, // op: BOOTREQUEST
            0x01, // htype: Ethernet
            0x06, // hlen: 6
            0x00, // hops: 0
            0xde, 0xad, 0xbe, 0xef, // transaction ID
            0x00, 0x00, // seconds
            0x00, 0x00, // flags
            0x00, 0x00, 0x00, 0x00, // ciaddr
            0x00, 0x00, 0x00, 0x00, // yiaddr
            0x00, 0x00, 0x00, 0x00, // siaddr
            0x00, 0x00, 0x00, 0x00, // giaddr
            0xde, 0xad, 0xbe, 0xef, 0xca, 0xfe, // chaddr (MAC)
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // padding
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // sname
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, // file
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, // magic cookie DHCP
            0x63, 0x82, 0x53, 0x63, // DHCP Magic Cookie
            0x35, 0x01, 0x01, // DHCP option 53: DISCOVER
            0xff, // end option
        ]),
        // Chargen
        19 => Some(b"\x0d\x0a"),
        // Echo
        7 => Some(b"\x0d\x0a"),
        // Daytime
        13 => Some(b"\x0d\x0a"),
        // Time
        37 => Some(b"\x0d\x0a"),
        // VxWorks WDB Agent
        17185 => Some(b"\x72\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x14\x00\x00\x00\x00\x00\x00\x00\x00"),
        // Quake game server
        27960 => Some(b"\xff\xff\xff\xff\x67\x65\x74\x73\x74\x61\x74\x75\x73\x0a"),
        _ => None,
    }
}

/// Returns an empty UDP payload for ports with no known probe
fn empty_probe() -> &'static [u8] {
    b""
}

// ─── Port State ───────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum UdpPortState {
    Unknown,
    Open,
    Closed,     // ICMP Port Unreachable received
    Filtered,   // No response after all retries
}

// ─── Capture message types ────────────────────────────────────────────────────

enum CaptureEvent {
    /// Port confirmed closed via ICMP Port Unreachable
    Closed(u16),
    /// UDP response received — port is open
    Open(u16),
    /// ICMP rate limiting detected (too many unreachables in short window)
    IcmpRateLimited,
}

struct CtlStop;

// ─── pcap codec ──────────────────────────────────────────────────────────────

struct PktCodec;

impl PacketCodec for PktCodec {
    type Item = Box<[u8]>;

    fn decode(&mut self, packet: pcap::Packet) -> Self::Item {
        packet.data.into()
    }
}

// ─── Packet analysis ─────────────────────────────────────────────────────────

fn src_port_from_ipv4_icmp(pkt: &Ipv4Packet) -> Option<u16> {
    let header_len =
        pkt.get_header_length() as usize * BITS_PER_WORD / BITS_PER_BYTE;
    let icmp_start = L2_FRAME_OFFSET + header_len;
    let raw = pkt.packet();

    if raw.len() < icmp_start + 8 {
        return None;
    }
    let icmp = IcmpPacket::new(&raw[icmp_start..])?;
    if icmp.get_icmp_type() != IcmpTypes::DestinationUnreachable {
        return None;
    }
    if icmp.get_icmp_code() != IcmpCodes::DestinationPortUnreachable {
        return None;
    }
    // ICMP unreachable payload: 8 bytes ICMP header + original IP header + first 8 bytes of original UDP
    let payload = icmp.payload();
    // original IP header is at offset 4 (after 4-byte "unused" field in ICMP)
    let orig_ip_start = 4usize;
    if payload.len() < orig_ip_start + 28 {
        return None;
    }
    let orig_ip = Ipv4Packet::new(&payload[orig_ip_start..])?;
    if orig_ip.get_next_level_protocol() != IpNextHeaderProtocols::Udp {
        return None;
    }
    let orig_ip_hlen = orig_ip.get_header_length() as usize * BITS_PER_WORD / BITS_PER_BYTE;
    let orig_udp = &payload[orig_ip_start + orig_ip_hlen..];
    if orig_udp.len() < 4 {
        return None;
    }
    // destination port of the original UDP packet = the port we sent to
    let dst_port = u16::from_be_bytes([orig_udp[2], orig_udp[3]]);
    Some(dst_port)
}

fn src_port_from_ipv6_icmp(pkt: &Ipv6Packet) -> Option<u16> {
    let raw = pkt.packet();
    const IPV6_HEADER_LEN: usize = 40;
    if raw.len() < IPV6_HEADER_LEN + 8 {
        return None;
    }
    if pkt.get_next_header() != IpNextHeaderProtocols::Icmpv6 {
        return None;
    }
    let icmp6 = Icmpv6Packet::new(&raw[IPV6_HEADER_LEN..])?;
    if icmp6.get_icmpv6_type() != Icmpv6Types::DestinationUnreachable {
        return None;
    }
    // ICMPv6 unreachable: 4 bytes unused + original IPv6 header (40 bytes) + 8 bytes UDP
    let payload = icmp6.payload();
    if payload.len() < 4 + IPV6_HEADER_LEN + 8 {
        return None;
    }
    let orig_ipv6 = Ipv6Packet::new(&payload[4..])?;
    if orig_ipv6.get_next_header() != IpNextHeaderProtocols::Udp {
        return None;
    }
    let orig_udp = &payload[4 + IPV6_HEADER_LEN..];
    let dst_port = u16::from_be_bytes([orig_udp[2], orig_udp[3]]);
    Some(dst_port)
}

fn src_port_from_ipv4_udp(pkt: &Ipv4Packet) -> Option<u16> {
    if pkt.get_next_level_protocol() != IpNextHeaderProtocols::Udp {
        return None;
    }
    let hlen = pkt.get_header_length() as usize * BITS_PER_WORD / BITS_PER_BYTE;
    let raw = pkt.packet();
    if raw.len() < hlen + 4 {
        return None;
    }
    // bytes 0..1 = src port of the response = port we probed
    let src_port = u16::from_be_bytes([raw[hlen], raw[hlen + 1]]);
    Some(src_port)
}

fn src_port_from_ipv6_udp(pkt: &Ipv6Packet) -> Option<u16> {
    if pkt.get_next_header() != IpNextHeaderProtocols::Udp {
        return None;
    }
    const IPV6_HEADER_LEN: usize = 40;
    let raw = pkt.packet();
    if raw.len() < IPV6_HEADER_LEN + 4 {
        return None;
    }
    let src_port = u16::from_be_bytes([raw[IPV6_HEADER_LEN], raw[IPV6_HEADER_LEN + 1]]);
    Some(src_port)
}

fn process_packet(data: &[u8], target: IpAddr) -> Option<CaptureEvent> {
    if data.len() <= MIN_ALLOWED_PACKET_LEN {
        return None;
    }
    // Ether type is at bytes 14..16
    let ether_type = &data[14..16];
    let payload = &data[L2_FRAME_OFFSET..];

    match ether_type {
        [0x08, 0x00] => {
            // IPv4
            let ipv4 = Ipv4Packet::new(payload)?;
            let src_addr = IpAddr::V4(ipv4.get_source());

            // Only care about packets from our target
            if src_addr != target {
                return None;
            }

            match ipv4.get_next_level_protocol() {
                IpNextHeaderProtocols::Icmp => {
                    let port = src_port_from_ipv4_icmp(&ipv4)?;
                    Some(CaptureEvent::Closed(port))
                }
                IpNextHeaderProtocols::Udp => {
                    let port = src_port_from_ipv4_udp(&ipv4)?;
                    Some(CaptureEvent::Open(port))
                }
                _ => None,
            }
        }
        [0x86, 0xDD] => {
            // IPv6
            let ipv6 = Ipv6Packet::new(payload)?;
            let src_addr = IpAddr::V6(ipv6.get_source());

            if src_addr != target {
                return None;
            }

            match ipv6.get_next_header() {
                IpNextHeaderProtocols::Icmpv6 => {
                    let port = src_port_from_ipv6_icmp(&ipv6)?;
                    Some(CaptureEvent::Closed(port))
                }
                IpNextHeaderProtocols::Udp => {
                    let port = src_port_from_ipv6_udp(&ipv6)?;
                    Some(CaptureEvent::Open(port))
                }
                _ => None,
            }
        }
        _ => None,
    }
}

// ─── Raw UDP send ─────────────────────────────────────────────────────────────

fn send_udp_probe(target: IpAddr, port: u16, payload: &[u8]) -> std::io::Result<()> {
    let addr = SocketAddr::new(target, port);
    let bind_addr: SocketAddr = match target {
        IpAddr::V4(_) => "0.0.0.0:0".parse().unwrap(),
        IpAddr::V6(_) => "[::]:0".parse().unwrap(),
    };
    let sock = UdpSocket::bind(bind_addr)?;
    sock.send_to(payload, addr)?;
    Ok(())
}

// ─── ICMP rate-limit tracker ──────────────────────────────────────────────────

struct IcmpRateTracker {
    /// Timestamps of the last few received ICMP unreachable messages.
    /// We keep only the last N+1 to compute N inter-arrival intervals.
    timestamps: Vec<Instant>,
}

impl IcmpRateTracker {
    fn new() -> Self {
        Self { timestamps: Vec::new() }
    }

    /// Record a received ICMP unreachable.
    /// Returns `true` once we have enough samples and the **median** inter-arrival
    /// interval exceeds `ICMP_RATE_LIMIT_INTERVAL_THRESHOLD`, which indicates the
    /// target is throttling responses (e.g. Windows 1 ICMP/sec policy).
    ///
    /// A fast Linux host produces hundreds of ICMP/ms → tiny intervals → no trigger.
    /// A Windows host produces ~1 ICMP/sec → ~1 s intervals → triggers after
    /// `ICMP_RATE_LIMIT_MIN_SAMPLES + 1` received packets.
    fn record(&mut self) -> bool {
        self.timestamps.push(Instant::now());
        // Keep only enough history to compute ICMP_RATE_LIMIT_MIN_SAMPLES intervals
        let keep = ICMP_RATE_LIMIT_MIN_SAMPLES + 1;
        if self.timestamps.len() > keep {
            self.timestamps.drain(..self.timestamps.len() - keep);
        }
        if self.timestamps.len() < 2 {
            return false;
        }
        let mut intervals: Vec<Duration> = self.timestamps
            .windows(2)
            .map(|w| w[1].duration_since(w[0]))
            .collect();
        if intervals.len() < ICMP_RATE_LIMIT_MIN_SAMPLES {
            return false;
        }
        intervals.sort_unstable();
        let median = intervals[intervals.len() / 2];
        median >= ICMP_RATE_LIMIT_INTERVAL_THRESHOLD
    }
}

// ─── Capture task ─────────────────────────────────────────────────────────────

fn make_stream(
    cap: Capture<Inactive>,
    target: IpAddr,
) -> Result<PacketStream<Active, PktCodec>, pcap::Error> {
    let mut stream = cap
        .promisc(true)
        .immediate_mode(true)
        .timeout(DEFAULT_TIMEOUT * 1000)
        .open()?
        .setnonblock()?;
    // Filter capture to only packets relevant to the target UDP scan.
    // This avoids parsing unrelated high-volume traffic on busy hosts.
    let bpf = format!("host {} and (udp or icmp or icmp6)", target);
    stream.filter(&bpf, true)?;
    stream.stream(PktCodec)
}

async fn capture_task(
    cap: Capture<Inactive>,
    target: IpAddr,
    mut rx_ctl: Receiver<CtlStop>,
    tx_event: Sender<CaptureEvent>,
    rate_limited_flag: Arc<tokio::sync::RwLock<bool>>,
) -> Result<(), SynScanError> {
    let mut stream =
        make_stream(cap, target).map_err(|e| SynScanError::NoValidInterface(e.to_string()))?;
    let mut rate_tracker = IcmpRateTracker::new();

    debug!("UDP capture task started for target {}", target);

    loop {
        tokio::select! {
            pkt = stream.next() => {
                if let Some(Ok(data)) = pkt {
                    if let Some(event) = process_packet(&data, target) {
                        match &event {
                            CaptureEvent::Closed(_) => {
                                if rate_tracker.record() {
                                    // Set shared flag so send_task can slow down immediately
                                    *rate_limited_flag.write().await = true;
                                    let _ = tx_event.send(CaptureEvent::IcmpRateLimited).await;
                                }
                            }
                            CaptureEvent::Open(_) | CaptureEvent::IcmpRateLimited => {}
                        }
                        let _ = tx_event.send(event).await;
                    }
                }
            },
            ctl = rx_ctl.recv() => {
                if let Some(CtlStop) = ctl {
                    break;
                }
            }
        }
    }

    debug!("UDP capture task finished");
    Ok(())
}

// ─── Send task ────────────────────────────────────────────────────────────────

/// Send all probes as fast as possible (nmap-style burst), then wait for responses.
/// The post_send_wait is computed by the caller — it accounts for rate limiting
/// by waiting longer rather than slowing the send side.
async fn send_task(
    target: IpAddr,
    ports: Vec<u16>,
    tx_ctl: Sender<CtlStop>,
    post_send_wait: Duration,
) {
    for port in &ports {
        let payload = get_probe_for_port(*port).unwrap_or_else(empty_probe);
        if let Err(e) = send_udp_probe(target, *port, payload) {
            warn!("Failed to send UDP probe to {}:{}: {}", target, port, e);
        }
        if !INTER_PROBE_DELAY.is_zero() {
            sleep(INTER_PROBE_DELAY).await;
        }
    }

    debug!("UDP sweep sent {} probes, waiting {}ms for replies",
        ports.len(), post_send_wait.as_millis());
    sleep(post_send_wait).await;
    let _ = tx_ctl.send(CtlStop).await;
}

// ─── RTT-adaptive timeout ─────────────────────────────────────────────────────

struct RttTracker {
    samples: Vec<Duration>,
}

impl RttTracker {
    fn new() -> Self {
        Self { samples: Vec::new() }
    }

    fn record(&mut self, rtt: Duration) {
        self.samples.push(rtt);
    }

    fn mean(&self) -> Option<Duration> {
        if self.samples.is_empty() {
            return None;
        }
        let n = self.samples.len() as f64;
        let mean_secs = self.samples.iter().map(|d| d.as_secs_f64()).sum::<f64>() / n;
        Some(Duration::from_secs_f64(mean_secs))
    }

    fn std_dev(&self) -> Option<f64> {
        if self.samples.len() < 2 {
            return None;
        }
        let n = self.samples.len() as f64;
        let mean = self.samples.iter().map(|d| d.as_secs_f64()).sum::<f64>() / n;
        let variance = self.samples.iter()
            .map(|d| { let diff = d.as_secs_f64() - mean; diff * diff })
            .sum::<f64>() / n;
        Some(variance.sqrt())
    }

    /// Returns mean + 3σ capped at [100ms, 5s], or DEFAULT_PORT_TIMEOUT if no data.
    #[cfg(test)]
    fn estimated_timeout(&self) -> Duration {
        let mean = match self.mean() {
            Some(m) => m.as_secs_f64(),
            None => return DEFAULT_PORT_TIMEOUT,
        };
        let std_dev = self.std_dev().unwrap_or(0.0);
        let timeout_secs = (mean + 3.0 * std_dev).max(0.1).min(5.0);
        Duration::from_secs_f64(timeout_secs)
    }

    /// Compute adaptive post-send wait:
    /// - Fast host (mean RTT < 5ms): wait mean × multiplier, minimum 50ms
    /// - Slow/normal host: wait mean + 3σ × multiplier
    /// This avoids the fixed 500ms wait on fast LAN hosts.
    fn post_send_wait(&self) -> Duration {
        let mean = match self.mean() {
            Some(m) => m,
            None => return POST_SEND_WAIT_DEFAULT,
        };
        let std_dev_secs = self.std_dev().unwrap_or(0.0);

        let wait = if mean < FAST_HOST_RTT_THRESHOLD {
            // Very fast host — scale down aggressively
            let wait_secs = mean.as_secs_f64() * POST_SEND_RTT_MULTIPLIER;
            Duration::from_secs_f64(wait_secs).max(POST_SEND_WAIT_MIN)
        } else {
            // Normal host — mean + 3σ with multiplier
            let wait_secs = (mean.as_secs_f64() + 3.0 * std_dev_secs) * POST_SEND_RTT_MULTIPLIER;
            Duration::from_secs_f64(wait_secs)
                .max(POST_SEND_WAIT_MIN)
                .min(POST_SEND_WAIT_DEFAULT)
        };

        wait
    }
}

// ─── Main scan logic ──────────────────────────────────────────────────────────

struct UdpScanResults {
    open_ports: Vec<u16>,
    closed_ports: Vec<u16>,
    filtered_ports: Vec<u16>,
    passes: usize,
    icmp_rate_limited: bool,
}

async fn run_udp_scan(target: IpAddr, ports: BTreeSet<u16>) -> Result<UdpScanResults, SynScanError> {
    let scan_started = Instant::now();
    let state: Arc<Mutex<HashMap<u16, UdpPortState>>> = Arc::new(Mutex::new(
        ports.iter().map(|&p| (p, UdpPortState::Unknown)).collect(),
    ));

    let mut rtt_tracker = RttTracker::new();
    let mut icmp_rate_limited = false;
    let rate_limited_flag = Arc::new(tokio::sync::RwLock::new(false));
    let mut actual_passes = 0;

    for pass in 0..MAX_PASSES {
        if scan_started.elapsed() >= MAX_UDP_SCAN_RUNTIME {
            debug!(
                "UDP scan runtime budget ({:?}) reached on {} before pass {}; marking unresolved as filtered",
                MAX_UDP_SCAN_RUNTIME,
                target,
                pass + 1
            );
            break;
        }

        actual_passes = pass + 1;

        let to_scan: Vec<u16> = {
            let s = state.lock().await;
            let mut v: Vec<u16> = s.iter()
                .filter(|(_, v)| **v == UdpPortState::Unknown)
                .map(|(k, _)| *k)
                .collect();
            v.sort_unstable();
            v
        };

        if to_scan.is_empty() {
            break;
        }

        // Fast host optimisation: skip later passes if RTT is tiny and no rate limiting.
        if pass >= 2 {
            if let Some(mean) = rtt_tracker.mean() {
                if mean < FAST_HOST_RTT_THRESHOLD && !icmp_rate_limited {
                    debug!("Fast host (mean RTT={:?}): skipping pass {} — {} remaining ports are open|filtered",
                        mean, pass + 1, to_scan.len());
                    break;
                }
            }
        }

        // nmap-style: always send burst, compute how long to wait for responses.
        // On rate-limited hosts: wait proportional to unresolved port count (ICMP trickles in at ~1/sec).
        // On normal hosts: use RTT-based wait, capped at a sane default.
        let mut post_wait = if icmp_rate_limited {
            let wait = RATE_LIMITED_WAIT_PER_PORT * to_scan.len() as u32;
            wait.min(RATE_LIMITED_WAIT_MAX)
        } else if rtt_tracker.mean().is_some() {
            rtt_tracker.post_send_wait()
        } else {
            POST_SEND_WAIT_DEFAULT
        };

        // Do not exceed the host-level runtime budget.
        if let Some(remaining) = MAX_UDP_SCAN_RUNTIME.checked_sub(scan_started.elapsed()) {
            post_wait = post_wait.min(remaining);
        } else {
            break;
        }

        if post_wait.is_zero() {
            debug!(
                "No remaining UDP runtime budget on {}; stopping scan loop at pass {}",
                target,
                pass + 1
            );
            break;
        }

        debug!("UDP scan pass {}/{}: {} ports, post_wait={:?}, rate_limited={}",
            pass + 1, MAX_PASSES, to_scan.len(), post_wait, icmp_rate_limited);

        *rate_limited_flag.write().await = false;

        let cap = Capture::from_device("any")
            .map_err(|e| SynScanError::NoValidInterface(e.to_string()))?;

        let (tx_ctl, rx_ctl) = mpsc::channel::<CtlStop>(4);
        let (tx_event, mut rx_event) = mpsc::channel::<CaptureEvent>(4096);

        let state_clone = state.clone();
        let rate_flag_capture = rate_limited_flag.clone();

        let capture_handle = tokio::spawn(capture_task(
            cap, target, rx_ctl, tx_event, rate_flag_capture,
        ));
        let send_handle = tokio::spawn(send_task(
            target,
            to_scan.clone(),
            tx_ctl,
            post_wait,
        ));

        let pass_start = Instant::now();

        while let Some(event) = rx_event.recv().await {
            match event {
                CaptureEvent::Closed(port) => {
                    let mut s = state_clone.lock().await;
                    if let Some(st) = s.get_mut(&port) {
                        if *st == UdpPortState::Unknown {
                            let rtt = pass_start.elapsed();
                            rtt_tracker.record(rtt);
                            *st = UdpPortState::Closed;
                        }
                    }
                }
                CaptureEvent::Open(port) => {
                    let mut s = state_clone.lock().await;
                    if let Some(st) = s.get_mut(&port) {
                        if *st == UdpPortState::Unknown {
                            *st = UdpPortState::Open;
                        }
                    }
                }
                CaptureEvent::IcmpRateLimited => {
                    if !icmp_rate_limited {
                        icmp_rate_limited = true;
                        debug!("ICMP rate limiting detected from target {} — will extend wait on next pass",
                            target);
                    }
                }
            }
        }

        send_handle.await.unwrap();
        capture_handle.await.unwrap().unwrap();
    }

    // Any remaining Unknown after all passes → Filtered (open|filtered)
    {
        let mut s = state.lock().await;
        for v in s.values_mut() {
            if *v == UdpPortState::Unknown {
                *v = UdpPortState::Filtered;
            }
        }
    }

    let s = state.lock().await;
    let mut open_ports: Vec<u16> = s.iter().filter(|(_, v)| **v == UdpPortState::Open).map(|(k, _)| *k).collect();
    let mut closed_ports: Vec<u16> = s.iter().filter(|(_, v)| **v == UdpPortState::Closed).map(|(k, _)| *k).collect();
    let mut filtered_ports: Vec<u16> = s.iter().filter(|(_, v)| **v == UdpPortState::Filtered).map(|(k, _)| *k).collect();

    open_ports.sort_unstable();
    closed_ports.sort_unstable();
    filtered_ports.sort_unstable();

    Ok(UdpScanResults {
        open_ports,
        closed_ports,
        filtered_ports,
        passes: actual_passes,
        icmp_rate_limited,
    })
}

// ─── NASL entry point ─────────────────────────────────────────────────────────

#[nasl_function]
async fn plugin_run_udp_scanner(context: &ScanCtx<'_>) -> Result<(), FnError> {
    let target_ip = context.target().ip_addr();
    let configured_ports = context.target().ports_udp().clone();

    // If the scan config provides a port list, intersect it with our top-N list
    // to keep the scan tractable. If no ports are configured, use top-N directly.
    let ports: BTreeSet<u16> = if configured_ports.is_empty() {
        TOP_UDP_PORTS.iter().copied().collect()
    } else if configured_ports.len() > MAX_UDP_PORTS {
        let top_set: BTreeSet<u16> = TOP_UDP_PORTS.iter().copied().collect();
        configured_ports.intersection(&top_set).copied().collect()
    } else {
        configured_ports
    };

    if ports.is_empty() {
        debug!("No UDP ports configured for target {}, skipping UDP scan", target_ip);
        return Ok(());
    }

    debug!("Starting UDP scan of {} ports on {}", ports.len(), target_ip);

    let results = run_udp_scan(target_ip, ports)
        .await
        .map_err(|e| FnError::from(e))?;

    // Register open ports in Knowledge Base
    for &port in &results.open_ports {
        scanner_add_port_shared(context, Port::from(port), Some("udp"))?;
        debug!("UDP port {} is open on {}", port, target_ip);
    }

    // Mark host as UDP-scanned
    context.set_kb_item(KbKey::Host(Host::Udp), KbItem::Boolean(true))?;

    // Store statistics
    context.set_kb_item(
        KbKey::UdpScanner(UdpScanner::NbPasses),
        KbItem::Number(results.passes as i64),
    )?;
    context.set_kb_item(
        KbKey::UdpScanner(UdpScanner::OpenPortsNb),
        KbItem::Number(results.open_ports.len() as i64),
    )?;
    context.set_kb_item(
        KbKey::UdpScanner(UdpScanner::ClosedPortsNb),
        KbItem::Number(results.closed_ports.len() as i64),
    )?;
    context.set_kb_item(
        KbKey::UdpScanner(UdpScanner::FilteredPortsNb),
        KbItem::Number(results.filtered_ports.len() as i64),
    )?;
    context.set_kb_item(
        KbKey::UdpScanner(UdpScanner::IcmpRateLimit),
        KbItem::Boolean(results.icmp_rate_limited),
    )?;

    debug!(
        "UDP scan complete: {} open, {} closed, {} filtered, {} passes, rate_limited={}",
        results.open_ports.len(),
        results.closed_ports.len(),
        results.filtered_ports.len(),
        results.passes,
        results.icmp_rate_limited,
    );

    Ok(())
}

// ─── Module registration ──────────────────────────────────────────────────────

pub struct UdpScan;

function_set! {
    UdpScan,
    (plugin_run_udp_scanner)
}

// ─── Unit tests ───────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{IpAddr, Ipv4Addr};

    // ── Payload database ─────────────────────────────────────────────────────

    #[test]
    fn probe_dns_port_53_is_valid() {
        let probe = get_probe_for_port(53).expect("DNS probe must exist");
        // Transaction ID (2 bytes) + flags (2 bytes) + question count = 1
        assert!(probe.len() >= 12, "DNS probe too short: {} bytes", probe.len());
        // QDCOUNT should be 1
        assert_eq!(probe[4], 0x00);
        assert_eq!(probe[5], 0x01);
    }

    #[test]
    fn probe_ntp_port_123_has_correct_mode() {
        let probe = get_probe_for_port(123).expect("NTP probe must exist");
        assert_eq!(probe.len(), 48, "NTP packet must be 48 bytes");
        // First byte: 0x1b = LI=0, VN=3 (version 3), Mode=3 (client)
        assert_eq!(probe[0], 0x1b);
    }

    #[test]
    fn probe_snmp_port_161_is_valid() {
        let probe = get_probe_for_port(161).expect("SNMP probe must exist");
        // SNMP starts with SEQUENCE tag 0x30
        assert_eq!(probe[0], 0x30, "SNMP probe must start with SEQUENCE");
    }

    #[test]
    fn probe_tftp_port_69_has_rrq_opcode() {
        let probe = get_probe_for_port(69).expect("TFTP probe must exist");
        // RRQ opcode = 0x00 0x01
        assert_eq!(probe[0], 0x00);
        assert_eq!(probe[1], 0x01);
    }

    #[test]
    fn probe_ssdp_port_1900_contains_msearch() {
        let probe = get_probe_for_port(1900).expect("SSDP probe must exist");
        let text = std::str::from_utf8(probe).expect("SSDP probe must be valid UTF-8");
        assert!(text.contains("M-SEARCH"), "SSDP probe must contain M-SEARCH");
        assert!(text.contains("ssdp:discover"), "SSDP probe must contain ssdp:discover");
    }

    #[test]
    fn probe_sip_port_5060_is_options_request() {
        let probe = get_probe_for_port(5060).expect("SIP probe must exist");
        let text = std::str::from_utf8(probe).expect("SIP probe must be valid UTF-8");
        assert!(text.starts_with("OPTIONS"), "SIP probe must start with OPTIONS");
    }

    #[test]
    fn probe_unknown_port_returns_none() {
        assert!(get_probe_for_port(9999).is_none());
        assert!(get_probe_for_port(12345).is_none());
        assert!(get_probe_for_port(0).is_none());
    }

    #[test]
    fn empty_probe_is_empty_slice() {
        assert!(empty_probe().is_empty());
    }

    // ── ICMP rate limit tracker ───────────────────────────────────────────────

    #[test]
    fn icmp_rate_tracker_fast_host_no_trigger() {
        // Simulate a fast Linux host: inject ICMP_RATE_LIMIT_MIN_SAMPLES+1 timestamps
        // all within a few milliseconds of each other — should NOT trigger rate limit.
        let mut tracker = IcmpRateTracker::new();
        let base = Instant::now();
        for i in 0..=(ICMP_RATE_LIMIT_MIN_SAMPLES) {
            tracker.timestamps.push(base + Duration::from_millis(i as u64));
        }
        // record() pops one more near-zero-interval sample — still fast
        assert!(
            !tracker.record(),
            "Fast host with sub-ms intervals must NOT trigger rate limit"
        );
    }

    #[test]
    fn icmp_rate_tracker_detects_windows_rate_limit() {
        // Simulate a Windows host: inject timestamps ~1 sec apart.
        let mut tracker = IcmpRateTracker::new();
        let base = Instant::now()
            .checked_sub(Duration::from_secs((ICMP_RATE_LIMIT_MIN_SAMPLES + 2) as u64))
            .unwrap_or_else(Instant::now);
        for i in 0..=ICMP_RATE_LIMIT_MIN_SAMPLES {
            tracker.timestamps.push(base + Duration::from_secs(i as u64));
        }
        // record() adds one more ~1 sec later sample — median ≈ 1s → trigger
        assert!(
            tracker.record(),
            "Windows-style 1 ICMP/sec spacing must trigger rate limit"
        );
    }

    #[test]
    fn icmp_rate_tracker_insufficient_samples_no_trigger() {
        let mut tracker = IcmpRateTracker::new();
        // Fewer than ICMP_RATE_LIMIT_MIN_SAMPLES intervals — cannot decide yet
        for _ in 0..(ICMP_RATE_LIMIT_MIN_SAMPLES - 1) {
            assert!(
                !tracker.record(),
                "Should not trigger before enough samples are collected"
            );
        }
    }

    // ── RTT tracker ──────────────────────────────────────────────────────────

    #[test]
    fn rtt_tracker_returns_default_when_empty() {
        let tracker = RttTracker::new();
        assert_eq!(tracker.estimated_timeout(), DEFAULT_PORT_TIMEOUT);
        assert!(tracker.mean().is_none());
        assert!(tracker.std_dev().is_none());
    }

    #[test]
    fn rtt_tracker_with_stable_samples() {
        let mut tracker = RttTracker::new();
        // 5 identical 100ms samples → mean=0.1s, std_dev=0, timeout=0.1s
        for _ in 0..5 {
            tracker.record(Duration::from_millis(100));
        }
        let t = tracker.estimated_timeout();
        assert!(t >= Duration::from_millis(100), "timeout must be >= mean");
        assert!(t <= Duration::from_secs(5), "timeout must be capped at 5s");
    }

    #[test]
    fn rtt_tracker_caps_at_5_seconds() {
        let mut tracker = RttTracker::new();
        tracker.record(Duration::from_secs(1));
        tracker.record(Duration::from_secs(10));
        let t = tracker.estimated_timeout();
        assert!(t <= Duration::from_secs(5), "timeout must not exceed 5s cap");
    }

    #[test]
    fn rtt_tracker_post_send_wait_fast_host() {
        let mut tracker = RttTracker::new();
        // Simulate fast LAN host: 1ms RTT
        for _ in 0..10 {
            tracker.record(Duration::from_millis(1));
        }
        let wait = tracker.post_send_wait();
        // Should be much less than POST_SEND_WAIT_DEFAULT (500ms)
        assert!(wait < POST_SEND_WAIT_DEFAULT,
            "fast host wait {:?} should be < {:?}", wait, POST_SEND_WAIT_DEFAULT);
        // But at least POST_SEND_WAIT_MIN (50ms)
        assert!(wait >= POST_SEND_WAIT_MIN,
            "fast host wait {:?} should be >= {:?}", wait, POST_SEND_WAIT_MIN);
    }

    #[test]
    fn rtt_tracker_post_send_wait_slow_host() {
        let mut tracker = RttTracker::new();
        // Simulate slow WAN host: 200ms RTT
        for _ in 0..5 {
            tracker.record(Duration::from_millis(200));
        }
        let wait = tracker.post_send_wait();
        // Should be capped at POST_SEND_WAIT_DEFAULT
        assert!(wait <= POST_SEND_WAIT_DEFAULT,
            "slow host wait {:?} should be <= {:?}", wait, POST_SEND_WAIT_DEFAULT);
        assert!(wait >= POST_SEND_WAIT_MIN,
            "slow host wait {:?} should be >= {:?}", wait, POST_SEND_WAIT_MIN);
    }

    #[test]
    fn rtt_tracker_post_send_wait_no_data() {
        let tracker = RttTracker::new();
        assert_eq!(tracker.post_send_wait(), POST_SEND_WAIT_DEFAULT);
    }

    // ── Packet processing ─────────────────────────────────────────────────────

    #[test]
    fn process_packet_ignores_short_frames() {
        let target = IpAddr::V4(Ipv4Addr::new(192, 168, 1, 1));
        let short_data = vec![0u8; 10];
        assert!(process_packet(&short_data, target).is_none());
    }

    #[test]
    fn process_packet_ignores_unknown_ether_type() {
        let target = IpAddr::V4(Ipv4Addr::new(192, 168, 1, 1));
        // 17-byte frame with unknown EtherType (0x1234)
        let mut data = vec![0u8; 64];
        data[12] = 0x12;
        data[13] = 0x34;
        assert!(process_packet(&data, target).is_none());
    }

    // ── Top ports ──────────────────────────────────────────────────────────────

    #[test]
    fn top_udp_ports_has_correct_count() {
        assert_eq!(TOP_UDP_PORTS.len(), MAX_UDP_PORTS);
    }

    #[test]
    fn top_udp_ports_contains_common_services() {
        let set: BTreeSet<u16> = TOP_UDP_PORTS.iter().copied().collect();
        assert!(set.contains(&53), "DNS");
        assert!(set.contains(&161), "SNMP");
        assert!(set.contains(&123), "NTP");
        assert!(set.contains(&137), "NetBIOS");
        assert!(set.contains(&5353), "mDNS");
    }

    // ── KB key format ─────────────────────────────────────────────────────────

    #[test]
    fn udp_scanner_kb_keys_format_correctly() {
        use crate::storage::items::kb::{KbKey, UdpScanner};

        assert_eq!(
            KbKey::UdpScanner(UdpScanner::NbPasses).to_string(),
            "UDPScanner/NbPasses"
        );
        assert_eq!(
            KbKey::UdpScanner(UdpScanner::OpenPortsNb).to_string(),
            "UDPScanner/OpenPortsNb"
        );
        assert_eq!(
            KbKey::UdpScanner(UdpScanner::ClosedPortsNb).to_string(),
            "UDPScanner/ClosedPortsNb"
        );
        assert_eq!(
            KbKey::UdpScanner(UdpScanner::FilteredPortsNb).to_string(),
            "UDPScanner/FilteredPortsNb"
        );
        assert_eq!(
            KbKey::UdpScanner(UdpScanner::IcmpRateLimit).to_string(),
            "UDPScanner/IcmpRateLimit"
        );
    }
}
