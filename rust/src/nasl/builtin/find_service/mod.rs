// SPDX-FileCopyrightText: 2023 Greenbone AG
//
// SPDX-License-Identifier: GPL-2.0-or-later WITH x11vnc-openssl-exception

use std::{
    collections::HashMap,
    io::{self, Write},
    net::IpAddr,
    time::Duration,
};

use serde::{Deserialize, Serialize};
use thiserror::Error;
use regex::Regex;

use crate::nasl::{
    builtin::{
        host::get_host_name_shared,
        network::{OpenvasEncaps, socket::open_sock_tcp_vhost},
    },
    prelude::*,
};
use crate::storage::items::kb::{self, KbItem, KbKey};

use super::{
    network::socket::{NaslSocket, SocketError, make_tcp_socket},
    preferences::{
        get_plugin_preference_fname, plug_set_ssl_ca_file, plug_set_ssl_cert, plug_set_ssl_key,
        plug_set_ssl_password,
    },
};

const TIMEOUT_MILLIS: u64 = 5000;

#[derive(Debug, Error)]
pub enum FindServiceError {
    #[error("{0}")]
    Socket(#[from] SocketError),
    #[error("JSON parsing error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("IO error: {0}")]
    Io(#[from] io::Error),
    #[error("Regex error: {0}")]
    Regex(#[from] regex::Error),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServiceDefinitions {
    pub version: String,
    pub description: String,
    pub services: Vec<Service>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Service {
    pub name: String,
    pub service_key: Option<String>,
    pub description: String,
    pub detections: Vec<Detection>,
    pub ports: Vec<u16>,
    pub save_banner: bool,
    pub generate_result: GenerateResult,
    pub kb_entries: HashMap<String, String>,
}

impl Service {
    fn key(&self) -> String {
        self.service_key.as_ref().unwrap_or(&self.name).clone()
    }
}

pub type ServiceId = String;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Detection {
    Banner(BannerDetection),
    Https,
    Http,
    Ssh,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "banner_detection_type", rename_all = "snake_case")]
pub enum BannerDetection {
    Contains {
        value: String,
        #[serde(default)]
        case_sensitive: bool,
    },
    StartsWith {
        value: String,
        #[serde(default)]
        case_sensitive: bool,
    },
    Equals {
        value: String,
        #[serde(default)]
        case_sensitive: bool,
    },
    ContainsHex {
        value: String,
        position: Option<usize>,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GenerateResult {
    pub enabled: bool,
    pub is_vulnerability: bool,
    pub message: String,
}

enum ReadResult {
    Data(Vec<u8>),
    Timeout,
}

struct DetectedService {
    id: ServiceId,
    banner: Vec<u8>,
}

enum ScanPortResult {
    Service(DetectedService),
    Timeout,
    NoMatch,
}

impl BannerDetection {
    fn matches(&self, banner: &[u8]) -> bool {
        let banner_str = String::from_utf8_lossy(banner);
        match self {
            BannerDetection::Contains {
                value,
                case_sensitive,
            } => {
                if *case_sensitive {
                    banner_str.contains(value)
                } else {
                    banner_str.to_lowercase().contains(&value.to_lowercase())
                }
            }
            BannerDetection::StartsWith {
                value,
                case_sensitive,
            } => {
                if *case_sensitive {
                    banner_str.starts_with(value)
                } else {
                    banner_str.to_lowercase().starts_with(&value.to_lowercase())
                }
            }
            BannerDetection::Equals {
                value,
                case_sensitive,
            } => {
                if *case_sensitive {
                    banner_str.trim() == *value
                } else {
                    banner_str.trim().to_lowercase() == value.to_lowercase()
                }
            }
            BannerDetection::ContainsHex { value, position } => match hex::decode(value) {
                Ok(hex_bytes) => {
                    if let Some(pos) = position {
                        banner.len() > pos + hex_bytes.len()
                            && banner[*pos..*pos + hex_bytes.len()] == hex_bytes
                    } else {
                        banner
                            .windows(hex_bytes.len())
                            .any(|window| window == hex_bytes)
                    }
                }
                Err(_) => false,
            },
        }
    }
}

impl Detection {
    fn matches(&self, banner_or_http_response: &[u8]) -> Result<bool, FindServiceError> {
        match self {
            Detection::Banner(banner_pattern) => {
                Ok(banner_pattern.matches(banner_or_http_response))
            }
            Detection::Https => Ok(Self::detect_https(banner_or_http_response)),
            Detection::Http => Ok(Self::detect_http_response(banner_or_http_response)),
            Detection::Ssh => Ok(Self::detect_ssh_banner(banner_or_http_response)),
        }
    }

    fn detect_https(banner: &[u8]) -> bool {
        // When we use a TLS socket, the received payload is already decrypted,
        // so HTTPS detection is equivalent to detecting an HTTP response.
        Self::detect_http_response(banner)
    }

    fn detect_http_response(banner: &[u8]) -> bool {
        let response = String::from_utf8_lossy(banner);
        response.contains("HTTP/1.0")
            || response.contains("HTTP/1.1")
            || response.contains("HTTP/2")
            || response.to_ascii_lowercase().contains("<html")
    }

    fn detect_ssh_banner(banner: &[u8]) -> bool {
        let response = String::from_utf8_lossy(banner);
        response.to_ascii_lowercase().contains("ssh-")
    }
}

struct ServiceDetector {
    services: ServiceDefinitions,
}

#[derive(Debug, Clone)]
struct AppFingerprint {
    name: String,
    version: Option<String>,
    product: Option<String>,
}

impl ServiceDetector {
    fn new() -> Result<Self, FindServiceError> {
        let json_content = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/data/service_definitions.json"
        ));
        let definitions: ServiceDefinitions = serde_json::from_str(json_content)?;
        Ok(ServiceDetector {
            services: definitions,
        })
    }

    fn detect_service(
        &self,
        banner: &[u8],
        port: u16,
    ) -> Result<Option<DetectedService>, FindServiceError> {
        for service in &self.services.services {
            if !service.ports.is_empty() && !service.ports.contains(&port) {
                continue;
            }

            for pattern in &service.detections {
                if pattern.matches(banner)? {
                    return Ok(Some(DetectedService {
                        id: service.name.clone(),
                        banner: banner.to_vec(),
                    }));
                }
            }
        }
        Ok(None)
    }

    fn handle_detected_service(
        &self,
        context: &ScanCtx<'_>,
        service: DetectedService,
        port: u16,
    ) -> Result<(), FnError> {
        let banner = service.banner;
        // The following lookup is in O(n^2). However, since the
        // number of services is likely to be small, this is very
        // unlikely to become a performance problem, so that I prefer
        // the simplicity of this approach (as opposed to using a
        // HashMap).
        let service = self
            .services
            .services
            .iter()
            .find(|s| s.name == service.id)
            .unwrap();

        add_kb_entries(context, service, port, banner)?;
        self.add_app_fingerprint(context, service, port)?;

        if service.generate_result.enabled {
            if service.generate_result.is_vulnerability {
                tracing::warn!(
                    "Security alert on port {}: {}",
                    port,
                    service.generate_result.message
                );
            } else {
                tracing::info!(
                    "Service detected on port {}: {}",
                    port,
                    service.generate_result.message
                );
            }
        }

        Ok(())
    }

    fn add_app_fingerprint(
        &self,
        context: &ScanCtx<'_>,
        service: &Service,
        port: u16,
    ) -> Result<(), FnError> {
        // Read back the banner we already stored for this port.
        let banner_key = format!("Banner/{port}");
        let banner = context
            .get_kb_item(&KbKey::Custom(banner_key))
            .ok()
            .and_then(|values| values.into_iter().last())
            .and_then(|v| match v {
                KbItem::Data(b) => Some(b),
                KbItem::String(s) => Some(s.into_bytes()),
                _ => None,
            })
            .unwrap_or_default();

        let fp = extract_app_fingerprint(service, &banner);

        context.set_kb_item(
            KbKey::Custom(format!("App/{port}/name")),
            KbItem::String(fp.name.clone()),
        )?;

        context.set_kb_item(
            KbKey::Custom(format!("App/{port}/product")),
            KbItem::String(fp.product.unwrap_or(fp.name)),
        )?;

        if let Some(version) = fp.version {
            context.set_kb_item(
                KbKey::Custom(format!("App/{port}/version")),
                KbItem::String(version),
            )?;
        }

        Ok(())
    }
}

fn extract_app_fingerprint(service: &Service, banner: &[u8]) -> AppFingerprint {
    let banner_str = String::from_utf8_lossy(banner);
    let name = service.key();
    let mut product = Some(service.description.clone());

    let version = match name.as_str() {
        "ssh" => first_regex_group(&banner_str, r"(?i)SSH-\d+\.\d+-([^\s\r\n]+)"),
        "www" | "http" | "https" => first_regex_group(&banner_str, r"(?i)Server:\s*[^\s/]+/([0-9][^\s\r\n]*)")
            .or_else(|| first_regex_group(&banner_str, r"(?i)\bnginx/([0-9][^\s\r\n]*)"))
            .or_else(|| first_regex_group(&banner_str, r"(?i)\bapache/?([0-9][^\s\r\n]*)")),
        "smtp" => first_regex_group(&banner_str, r"(?i)\b(?:ESMTP|SMTP)\s+([^\s\r\n]+)"),
        "ftp" => first_regex_group(&banner_str, r"(?i)\bFTP(?:\s+server)?\s+([0-9][^\s\r\n]*)"),
        "mysql" => first_regex_group(&banner_str, r"(?i)\b(?:mysql|mariadb)[\s/-]*([0-9][^\s\r\n]*)"),
        "postgresql" => first_regex_group(&banner_str, r"(?i)\bpostgres(?:ql)?[\s/-]*([0-9][^\s\r\n]*)"),
        _ => None,
    };

    if product.as_ref().is_some_and(|s| s.is_empty()) {
        product = None;
    }

    AppFingerprint {
        name,
        version,
        product,
    }
}

fn first_regex_group(haystack: &str, pattern: &str) -> Option<String> {
    let re = Regex::new(pattern).ok()?;
    let caps = re.captures(haystack)?;
    Some(caps.get(1)?.as_str().trim().to_string())
}

fn protocol_probes_for_port(port: u16) -> Vec<&'static [u8]> {
    let mut probes: Vec<&'static [u8]> = vec![];

    match port {
        21 | 2121 => probes.push(b"FEAT\r\n"),
        22 | 2222 => probes.push(b"SSH-2.0-openvas-probe\r\n"),
        25 | 465 | 587 => probes.push(b"EHLO openvas.local\r\n"),
        110 | 995 => probes.push(b"CAPA\r\n"),
        143 | 993 => probes.push(b"a001 CAPABILITY\r\n"),
        3306 => probes.push(b"\x00"),
        5432 => probes.push(b"\x00\x00\x00\x08\x04\xd2\x16\x2f"),
        _ => {}
    }

    // HTTP services are frequently exposed on non-standard ports (e.g. 9001),
    // so always probe for HTTP semantics to improve app-layer coverage.
    probes.push(b"HEAD / HTTP/1.0\r\nHost: target\r\n\r\n");
    probes.push(b"GET / HTTP/1.0\r\nHost: target\r\n\r\n");

    probes
}

fn add_kb_entries(
    context: &ScanCtx<'_>,
    service: &Service,
    port: u16,
    banner: Vec<u8>,
) -> Result<(), FnError> {
    for (key_template, value_template) in &service.kb_entries {
        let key = key_template.replace("{port}", &port.to_string());
        let value = value_template.replace("{port}", &port.to_string());

        context.set_kb_item(KbKey::Custom(key), KbItem::String(value))?;
    }

    context.set_kb_item(
        KbKey::Service(kb::Service::Custom(service.key())),
        KbItem::String(format!("{port}/tcp")),
    )?;

    context.set_kb_item(KbKey::KnownTcp(port), KbItem::String(service.key()))?;

    if service.save_banner {
        let banner_key = format!("Banner/{port}");
        context.set_kb_item(KbKey::Custom(banner_key), KbItem::Data(banner.clone()))?;

        // Legacy compatibility: many NASL checks rely on "<service>/banner/<port>"
        // keys (for web checks this is usually "www/banner/<port>").
        let service_banner_key = format!("{}/banner/{port}", service.key());
        context.set_kb_item(
            KbKey::Custom(service_banner_key),
            KbItem::String(String::from_utf8_lossy(&banner).to_string()),
        )?;
    }

    // Keep compatibility with legacy find_service behavior where SSL ports are
    // recorded as integer values under Transport/SSL.
    if service.name == "https" {
        context.set_kb_item(
            KbKey::Transport(kb::Transport::Ssl),
            KbItem::Number(port as i64),
        )?;
    }

    Ok(())
}

fn read_from_tcp_at_port(
    context: &ScanCtx,
    target: IpAddr,
    port: u16,
    test_tls: bool,
) -> Result<ReadResult, FindServiceError> {
    let mut socket = if test_tls {
        make_tcp_socket(target, port, 0)?
    } else {
        let vhost = get_host_name_shared(context)
            .ok()
            .and_then(|v| v.as_string().ok())
            .unwrap_or_else(|| target.to_string());
        match open_sock_tcp_vhost(
            context,
            target,
            Duration::from_millis(TIMEOUT_MILLIS),
            None,
            port,
            &vhost,
            OpenvasEncaps::Auto.into(),
        ) {
            Ok(Some(s)) => s,
            _ => {
                return Err(SocketError::FailedTlsNegotiation(
                    "It was not possible to create a tls socket".into(),
                )
                .into());
            }
        }
    };
    let mut buf = vec![0; 1024];
    let result = socket.read_with_timeout(&mut buf, Duration::from_millis(TIMEOUT_MILLIS));
    match result {
        Ok(pos) => {
            buf.truncate(pos);
            Ok(ReadResult::Data(buf))
        }
        Err(e) if e.kind() == io::ErrorKind::TimedOut => Ok(ReadResult::Timeout),
        Err(e) => Err(SocketError::IO(e).into()),
    }
}

fn try_probe_request(
    context: &ScanCtx,
    target: IpAddr,
    port: u16,
    probe: &[u8],
    over_tls: bool,
) -> Result<Vec<u8>, FindServiceError> {
    // TODO: Use a more robust approach that also takes HTTP2 into
    // account (such as using h2)
    let mut socket = if over_tls {
        let vhost = get_host_name_shared(context)
            .ok()
            .and_then(|v| v.as_string().ok())
            .unwrap_or_else(|| target.to_string());
        match open_sock_tcp_vhost(
            context,
            target,
            Duration::from_millis(TIMEOUT_MILLIS),
            None,
            port,
            &vhost,
            OpenvasEncaps::Auto.into(),
        ) {
            Ok(Some(s)) => s,
            _ => {
                return Err(SocketError::FailedTlsNegotiation(
                    "It was not possible to create a tls socket".into(),
                )
                .into());
            }
        }
    } else {
        make_tcp_socket(target, port, 0)?
    };

    match socket {
        NaslSocket::Tcp(ref mut tcp_conn) => {
            tcp_conn.write_all(probe).map_err(SocketError::IO)?;

            let mut buf = vec![0; 1024];
            let result =
                tcp_conn.read_with_timeout(&mut buf, Duration::from_millis(TIMEOUT_MILLIS));
            match result {
                Ok(pos) => {
                    buf.truncate(pos);
                    Ok(buf)
                }
                Err(e) => Err(SocketError::IO(e).into()),
            }
        }
        _ => unreachable!(),
    }
}

fn scan_port(
    context: &ScanCtx,
    detector: &ServiceDetector,
    target: IpAddr,
    port: u16,
) -> Result<ScanPortResult, FindServiceError> {
    let mut had_timeout = false;

    // 1) Passive banner read over plain TCP.
    match read_from_tcp_at_port(context, target, port, false) {
        Ok(ReadResult::Data(data)) => {
            if let Some(service) = detector.detect_service(&data, port)? {
                return Ok(ScanPortResult::Service(service));
            }
        }
        Ok(ReadResult::Timeout) => had_timeout = true,
        Err(e) => {
            tracing::debug!("Error reading plain TCP banner on port {}: {}", port, e);
        }
    }

    // 2) Passive banner read over TLS-capable socket.
    match read_from_tcp_at_port(context, target, port, true) {
        Ok(ReadResult::Data(data)) => {
            if let Some(service) = detector.detect_service(&data, port)? {
                return Ok(ScanPortResult::Service(service));
            }
        }
        Ok(ReadResult::Timeout) => had_timeout = true,
        Err(e) => {
            tracing::debug!("Error reading TLS banner on port {}: {}", port, e);
        }
    }

    // 3) Active probes to trigger protocol banners.
    for probe in protocol_probes_for_port(port) {
        for over_tls in [false, true] {
            match try_probe_request(context, target, port, probe, over_tls) {
                Ok(response) => {
                    if response.is_empty() {
                        continue;
                    }
                    if let Some(service) = detector.detect_service(&response, port)? {
                        return Ok(ScanPortResult::Service(service));
                    }
                }
                Err(e) => {
                    tracing::debug!("Probe failed on port {} (tls={}): {}", port, over_tls, e);
                }
            }
        }
    }

    if had_timeout {
        Ok(ScanPortResult::Timeout)
    } else {
        Ok(ScanPortResult::NoMatch)
    }
}

const TEST_SSL_PREF: usize = 1;
const CERT_FILE: usize = 6;
const KEY_FILE: usize = 7;
const PEM_PASS: usize = 8;
const CA_FILE: usize = 9;

fn find_service_ssl_set_prefs(context: &ScanCtx, register: &Register) -> Result<(), FnError> {
    let cert = get_plugin_preference_fname(register, context, None, Some(CERT_FILE)).ok();
    let key = get_plugin_preference_fname(register, context, None, Some(KEY_FILE)).ok();

    if key.is_some() || cert.is_some() {
        plug_set_ssl_cert(context, cert.clone().unwrap_or(key.clone().unwrap()))?;
        plug_set_ssl_key(context, key.unwrap_or(cert.unwrap()))?;
    };

    if let Ok(pem_pass) = get_plugin_preference_fname(register, context, None, Some(PEM_PASS)) {
        plug_set_ssl_password(context, pem_pass)?;
    };

    if let Ok(ca) = get_plugin_preference_fname(register, context, None, Some(CA_FILE)) {
        plug_set_ssl_ca_file(context, ca)?;
    };

    Ok(())
}

#[nasl_function]
fn plugin_run_find_service(context: &ScanCtx<'_>, register: &Register) -> NaslResult {
    if let NaslValue::String(val) = register
        .script_param(TEST_SSL_PREF)
        .unwrap_or(NaslValue::String("All".to_string()))
        && val.as_str() == "All"
    {
        find_service_ssl_set_prefs(context, register)?;
    }

    let detector = ServiceDetector::new()?;
    let open_ports = context.get_open_tcp_ports()?;
    for port in open_ports {
        match scan_port(context, &detector, context.target().ip_addr(), port) {
            Ok(ScanPortResult::Service(service)) => {
                detector.handle_detected_service(context, service, port)?;
            }
            Ok(ScanPortResult::Timeout) => {
                tracing::debug!("Timeout reading from port {}", port);
            }
            Ok(ScanPortResult::NoMatch) => {
                tracing::debug!("No service match found for port {}", port);
            }
            Err(e) => {
                tracing::warn!("Error scanning port {}: {}", port, e);
            }
        }
    }

    Ok(NaslValue::Null)
}

#[derive(Default)]
pub struct FindService;

function_set! {
    FindService,
    (
        plugin_run_find_service
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_file_valid() {
        // Implicitly check if the JSON is valid by
        // creating the ServiceDetector
        let detector = ServiceDetector::new();
        detector.unwrap();
    }

    #[test]
    fn http_detection_is_case_aware_enough() {
        assert!(Detection::detect_http_response(
            b"HTTP/1.1 200 OK\r\nServer: nginx/1.25.3\r\n\r\n"
        ));
        assert!(Detection::detect_http_response(
            b"<html><head><title>ok</title></head></html>"
        ));
    }

    #[test]
    fn probe_list_for_common_ports() {
        let http_probes = protocol_probes_for_port(80);
        assert!(http_probes.iter().any(|p| p.starts_with(b"GET /")));
        let alt_http_probes = protocol_probes_for_port(9001);
        assert!(alt_http_probes.iter().any(|p| p.starts_with(b"GET /")));

        let smtp_probes = protocol_probes_for_port(25);
        assert!(smtp_probes.iter().any(|p| p.starts_with(b"EHLO")));
    }

    #[test]
    fn fingerprint_extracts_web_version() {
        let service = Service {
            name: "http".to_string(),
            service_key: Some("www".to_string()),
            description: "HTTP Web Server".to_string(),
            detections: vec![],
            ports: vec![80],
            save_banner: true,
            generate_result: GenerateResult {
                enabled: true,
                is_vulnerability: false,
                message: "x".to_string(),
            },
            kb_entries: HashMap::new(),
        };
        let fp = extract_app_fingerprint(
            &service,
            b"HTTP/1.1 200 OK\r\nServer: nginx/1.26.0\r\n\r\n",
        );
        assert_eq!(fp.name, "www");
        assert_eq!(fp.version, Some("1.26.0".to_string()));
    }
}
