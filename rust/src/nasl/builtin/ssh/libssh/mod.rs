// SPDX-FileCopyrightText: 2023 Greenbone AG
//
// SPDX-License-Identifier: GPL-2.0-or-later WITH x11vnc-openssl-exception

//! Defines NASL ssh and sftp functions

mod channel;
mod session;

use std::net::{IpAddr, UdpSocket};
use std::{os::fd::AsRawFd, time::Duration};

use libssh_rs::{LogLevel, SshOption};
use russh::cipher;
use russh::keys::Algorithm;
use tokio::sync::{Mutex, MutexGuard};
use tracing::debug;
use std::time::Instant;

use super::Ssh;
use super::error::Result;
use super::sessions::make_connect_key;

pub use libssh_rs::AuthMethods;
pub use session::SshSession;

pub type SessionId = i32;
pub type Socket = std::os::raw::c_int;

// Currently, our tests are executed with a TRACE filter.  In a normal
// run, this translates to a `LogLevel` of `Functions`, which is very
// verbose.
//
// Since libssh prints its logs to stderr, its output is not filtered
// out by `cargo test`, resulting in tons of annoying output, even if
// the test passes.  To make sure this doesn't happen, we set
// `NoLogging` in all test runs.
#[cfg(test)]
fn get_log_level() -> LogLevel {
    LogLevel::NoLogging
}

#[cfg(not(test))]
fn get_log_level() -> LogLevel {
    use tracing::Level;
    use tracing_subscriber::filter::LevelFilter;
    let log_level = LevelFilter::current().into_level();
    match log_level {
        None => LogLevel::NoLogging,
        Some(Level::ERROR) | Some(Level::WARN) => LogLevel::Warning,
        Some(Level::INFO) => LogLevel::Protocol,
        Some(Level::DEBUG) => LogLevel::Packet,
        Some(Level::TRACE) => LogLevel::Functions,
    }
}

fn to_comma_separated_string<T: AsRef<str>>(items: &[T]) -> Option<String> {
    if items.is_empty() {
        None
    } else {
        Some(itertools::join(items.iter().map(|name| name.as_ref()), ","))
    }
}

type BorrowedSession<'a> = MutexGuard<'a, SshSession>;

impl Ssh {
    pub async fn find_id<'a>(
        &'a self,
        f: impl for<'b> Fn(&BorrowedSession<'b>) -> bool,
    ) -> Result<Option<SessionId>> {
        for id in self.ids() {
            let session = self.get_by_id(*id).await?;
            if f(&session) {
                return Ok(Some(session.id()));
            }
        }
        Ok(None)
    }

    /// Create a new session, but only add it to the list of active sessions
    /// if the given closure which modifies the session returns Ok(...).
    #[allow(clippy::too_many_arguments)]
    pub async fn connect(
        &mut self,
        socket: Option<Socket>,
        ip: IpAddr,
        port: u16,
        keytype: Vec<Algorithm>,
        csciphers: Vec<cipher::Name>,
        scciphers: Vec<cipher::Name>,
        timeout: Option<Duration>,
    ) -> Result<SessionId> {
        // Custom sockets (NASL `socket:` argument) are not cached/reused.
        if socket.is_some() {
            let id = self.next_session_id()?;
            let session = Mutex::new(SshSession::new(id)?);
            {
                let mut borrowed_session = session.lock().await;
                let connect_key = make_connect_key(
                    ip,
                    port,
                    true,
                );
                borrowed_session.custom_socket = true;
                borrowed_session.connect_key = connect_key;
                borrowed_session.ip_addr = ip;
                borrowed_session.port = port;
                borrowed_session.timeout = timeout;
                borrowed_session.keytype = keytype;
                borrowed_session.csciphers = csciphers;
                borrowed_session.scciphers = scciphers;
                borrowed_session.authenticated = false;
                borrowed_session.auth_login = None;
                borrowed_session.auth_cred_hash = None;

                let keytype = borrowed_session.keytype.clone();
                let csciphers = borrowed_session.csciphers.clone();
                let scciphers = borrowed_session.scciphers.clone();
                let timeout = borrowed_session.timeout.clone();
                if let Err(e) = self
                    .try_connect(
                        &mut borrowed_session,
                        socket,
                        ip,
                        port,
                        keytype,
                        csciphers,
                        scciphers,
                        timeout,
                    )
                    .await
                {
                    borrowed_session.disconnect().await?;
                    return Err(e);
                }
            }
            self.insert(id, session, None);
            return Ok(id);
        }

        let connect_key = make_connect_key(
            ip,
            port,
            false,
        );

        if let Some(existing_id) = self.active_session_for_connect_key(&connect_key) {
            return Ok(existing_id);
        }

        let now = Instant::now();
        if let Some(session) = self.take_cached(&connect_key, now) {
            let id = self.next_session_id()?;
            {
                let mut borrowed_session = session.lock().await;
                borrowed_session.id = id;
            }
            self.insert(id, session, Some(connect_key.clone()));
            return Ok(id);
        }

        // Cache miss: create a new transport and connect.
        let id = self.next_session_id()?;
        let session = Mutex::new(SshSession::new(id)?);
        {
            let mut borrowed_session = session.lock().await;
            borrowed_session.custom_socket = false;
            borrowed_session.connect_key = connect_key.clone();
            borrowed_session.ip_addr = ip;
            borrowed_session.port = port;
            borrowed_session.timeout = timeout;
            borrowed_session.keytype = keytype;
            borrowed_session.csciphers = csciphers;
            borrowed_session.scciphers = scciphers;
            borrowed_session.authenticated = false;
            borrowed_session.auth_login = None;
            borrowed_session.auth_cred_hash = None;

            let ip_addr = borrowed_session.ip_addr;
            let port_ = borrowed_session.port;
            let keytype = borrowed_session.keytype.clone();
            let csciphers = borrowed_session.csciphers.clone();
            let scciphers = borrowed_session.scciphers.clone();
            let timeout = borrowed_session.timeout.clone();
            if let Err(e) = self
                .try_connect(
                    &mut borrowed_session,
                    None,
                    ip_addr,
                    port_,
                    keytype,
                    csciphers,
                    scciphers,
                    timeout,
                )
                .await
            {
                borrowed_session.disconnect().await?;
                return Err(e);
            }
        }
        self.insert(id, session, Some(connect_key));
        Ok(id)
    }

    /// Connect (or reconnect) and insert under a specific `session_id`.
    /// This is used for credential mismatch handling.
    #[allow(clippy::too_many_arguments)]
    pub async fn connect_with_session_id(
        &mut self,
        session_id: SessionId,
        socket: Option<Socket>,
        ip: IpAddr,
        port: u16,
        keytype: Vec<Algorithm>,
        csciphers: Vec<cipher::Name>,
        scciphers: Vec<cipher::Name>,
        timeout: Option<Duration>,
    ) -> Result<()> {
        let session = Mutex::new(SshSession::new(session_id)?);
        {
            let mut borrowed_session = session.lock().await;
            let connect_key = make_connect_key(
                ip,
                port,
                socket.is_some(),
            );

            borrowed_session.custom_socket = socket.is_some();
            borrowed_session.connect_key = connect_key;
            borrowed_session.ip_addr = ip;
            borrowed_session.port = port;
            borrowed_session.timeout = timeout;
            borrowed_session.keytype = keytype;
            borrowed_session.csciphers = csciphers;
            borrowed_session.scciphers = scciphers;
            borrowed_session.authenticated = false;
            borrowed_session.auth_login = None;
            borrowed_session.auth_cred_hash = None;

            let ip_addr = borrowed_session.ip_addr;
            let port_ = borrowed_session.port;
            let keytype = borrowed_session.keytype.clone();
            let csciphers = borrowed_session.csciphers.clone();
            let scciphers = borrowed_session.scciphers.clone();
            let timeout = borrowed_session.timeout.clone();
            if let Err(e) = self
                .try_connect(
                    &mut borrowed_session,
                    socket,
                    ip_addr,
                    port_,
                    keytype,
                    csciphers,
                    scciphers,
                    timeout,
                )
                .await
            {
                borrowed_session.disconnect().await?;
                return Err(e);
            }
        }

        self.insert(
            session_id,
            session,
            Some(make_connect_key(
                ip,
                port,
                socket.is_some(),
            )),
        );
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    async fn try_connect(
        &mut self,
        session: &mut BorrowedSession<'_>,
        socket: Option<Socket>,
        ip: IpAddr,
        port: u16,
        keytype: Vec<Algorithm>,
        csciphers: Vec<cipher::Name>,
        scciphers: Vec<cipher::Name>,
        timeout: Option<Duration>,
    ) -> Result<()> {
        let ip_str = ip.to_string();
        session.set_option(SshOption::LogLevel(get_log_level()))?;
        session.set_option(SshOption::Hostname(ip_str.clone()))?;
        session.set_option(SshOption::KnownHosts(Some("/dev/null".to_owned())))?;
        if let Some(timeout) = timeout {
            session.set_option(SshOption::Timeout(timeout))?;
        }
        if let Some(keytype) = to_comma_separated_string(&keytype) {
            session.set_option(SshOption::HostKeys(keytype))?;
        }
        if let Some(csciphers) = to_comma_separated_string(&csciphers) {
            session.set_option(SshOption::CiphersCS(csciphers))?;
        }
        if let Some(scciphers) = to_comma_separated_string(&scciphers) {
            session.set_option(SshOption::CiphersSC(scciphers))?;
        }
        session.set_option(SshOption::Port(port))?;

        if let Some(socket) = socket {
            // This is a fake raw socket.
            // TODO: implement openvas_get_socket_from_connection()
            let my_sock = UdpSocket::bind("127.0.0.1:0").unwrap();
            debug!(
                ip_str,
                sock_fd = my_sock.as_raw_fd(),
                nasl_sock = socket,
                "Setting SSH fd for socket",
            );
            session.set_option(SshOption::Socket(my_sock.as_raw_fd()))?;
        }
        debug!(
            ip_str,
            port = port,
            socket = socket,
            "Connecting to SSH server",
        );
        session.connect()?;
        Ok(())
    }

    pub async fn disconnect_and_remove(&mut self, session_id: SessionId) -> Result<()> {
        {
            let mut session = self.get_by_id(session_id).await?;
            session.disconnect().await?;
        }
        self.remove(session_id)
    }
}
