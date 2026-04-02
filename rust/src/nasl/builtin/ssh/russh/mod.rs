// SPDX-FileCopyrightText: 2025 Greenbone AG
//
// SPDX-License-Identifier: GPL-2.0-or-later WITH x11vnc-openssl-exception

mod session;

use russh::keys::Algorithm;
pub use session::SshSession;
use tokio::sync::Mutex;

use std::{net::IpAddr, time::Duration, time::Instant};

use super::error::Result;
use russh::cipher;

use super::sessions::SshSessions;
use super::sessions::make_connect_key;

pub type SessionId = i32;
pub type Socket = i32;

type Port = u16;

// This is a 'clone' of the libssh::AuthMethods, so
// the capital case names are intentional.
#[allow(non_camel_case_types, clippy::upper_case_acronyms, unused)]
pub enum AuthMethods {
    PASSWORD,
    INTERACTIVE,
    PUBLIC_KEY,
}

impl SshSessions {
    #[allow(clippy::too_many_arguments)]
    pub async fn connect(
        &mut self,
        socket: Option<Socket>,
        ip_addr: IpAddr,
        port: Port,
        keytype: Vec<Algorithm>,
        csciphers: Vec<cipher::Name>,
        scciphers: Vec<cipher::Name>,
        timeout: Option<Duration>,
    ) -> Result<SessionId> {
        // Custom sockets are currently not supported for russh, so we don't cache them.
        if socket.is_some() {
            let id = self.next_session_id()?;
            let session = Mutex::new(
                SshSession::new(
                    id,
                    ip_addr,
                    port,
                    timeout,
                    keytype,
                    csciphers,
                    scciphers,
                    socket,
                )
                .await?,
            );
            self.insert(id, session, None);
            return Ok(id);
        }

        let connect_key = make_connect_key(ip_addr, port, false);

        if let Some(existing_id) = self.active_session_for_connect_key(&connect_key) {
            return Ok(existing_id);
        }

        let now = Instant::now();
        if let Some(session) = self.take_cached(&connect_key, now) {
            let id = self.next_session_id()?;
            {
                let mut borrowed_session = session.lock().await;
                borrowed_session.set_id(id);
            }
            self.insert(id, session, Some(connect_key.clone()));
            return Ok(id);
        }

        let id = self.next_session_id()?;
        let session = Mutex::new(
            SshSession::new(
                id, ip_addr, port, timeout, keytype, csciphers, scciphers, socket,
            )
            .await?,
        );
        self.insert(id, session, Some(connect_key));
        Ok(id)
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn connect_with_session_id(
        &mut self,
        session_id: SessionId,
        socket: Option<Socket>,
        ip_addr: IpAddr,
        port: Port,
        keytype: Vec<Algorithm>,
        csciphers: Vec<cipher::Name>,
        scciphers: Vec<cipher::Name>,
        timeout: Option<Duration>,
    ) -> Result<()> {
        let session = Mutex::new(
            SshSession::new(
                session_id,
                ip_addr,
                port,
                timeout,
                keytype,
                csciphers,
                scciphers,
                socket,
            )
            .await?,
        );
        self.insert(
            session_id,
            session,
            Some(make_connect_key(ip_addr, port, socket.is_some())),
        );
        Ok(())
    }

    pub async fn disconnect_and_remove(&mut self, session_id: SessionId) -> Result<()> {
        self.remove(session_id)
    }
}
