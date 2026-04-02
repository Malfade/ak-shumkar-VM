// SPDX-FileCopyrightText: 2025 Greenbone AG
//
// SPDX-License-Identifier: GPL-2.0-or-later WITH x11vnc-openssl-exception

use std::collections::{HashMap, HashSet};
use std::env;
use std::net::IpAddr;
use std::time::{Duration, Instant};

use tokio::sync::{Mutex, MutexGuard};

use super::error::SshErrorKind;
use super::{SessionId, SshSession, error::Result};

/// Default TTL for keeping an SSH transport around after `ssh_disconnect()`.
/// A longer TTL avoids reconnect storms on long scans where many VTs touch SSH.
/// Set `OPENVAS_SSH_POOL_TTL_SECS=0` for non-expiring cache entries.
const DEFAULT_SOFT_DISCONNECT_TTL_SECS: u64 = 15 * 60;

#[derive(Clone, Debug, Hash, PartialEq, Eq)]
pub struct ConnectKey {
    ip_addr: IpAddr,
    port: u16,
    custom_socket: bool,
}

impl ConnectKey {
    #[cfg(feature = "nasl-builtin-libssh")]
    pub fn placeholder() -> Self {
        Self {
            ip_addr: IpAddr::V4(std::net::Ipv4Addr::UNSPECIFIED),
            port: 0,
            custom_socket: false,
        }
    }
}

pub fn make_connect_key(
    ip_addr: IpAddr,
    port: u16,
    custom_socket: bool,
) -> ConnectKey {
    ConnectKey {
        ip_addr,
        port,
        custom_socket,
    }
}

type BorrowedSession<'a> = MutexGuard<'a, SshSession>;

pub const MIN_SESSION_ID: SessionId = 9000;

#[derive(Default)]
pub struct SshSessions {
    // We need a mutex around the `SshSession` here.
    // This is because it contains (depending on feature gates)
    // 1. a libssh::Channel, which is not `Send`.
    // 2. a russh::Channel, which is not `Send`.
    sessions: HashMap<SessionId, Mutex<SshSession>>,
    cache_by_connect_key: HashMap<ConnectKey, (Mutex<SshSession>, Instant)>,
    /// Live TCP transport for `(ip, port)` when `ssh_disconnect` has not been called yet.
    active_session_id_by_connect_key: HashMap<ConnectKey, SessionId>,
    connect_key_by_session_id: HashMap<SessionId, ConnectKey>,
    soft_disconnect_ttl: Option<Duration>,
}

impl SshSessions {
    fn soft_disconnect_ttl_from_env() -> Option<Duration> {
        let secs = env::var("OPENVAS_SSH_POOL_TTL_SECS")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(DEFAULT_SOFT_DISCONNECT_TTL_SECS);
        if secs == 0 {
            None
        } else {
            Some(Duration::from_secs(secs))
        }
    }

    fn ensure_ttl_initialized(&mut self) {
        if self.soft_disconnect_ttl.is_none() {
            self.soft_disconnect_ttl = Self::soft_disconnect_ttl_from_env();
        }
    }

    pub async fn get_by_id(&self, id: SessionId) -> Result<BorrowedSession<'_>> {
        Ok(self
            .sessions
            .get(&id)
            .ok_or(SshErrorKind::InvalidSessionId.with(id))?
            .lock()
            .await)
    }

    /// Return the next available session ID
    pub fn next_session_id(&self) -> Result<SessionId> {
        // Note that the first session ID we will
        // hand out is an arbitrary high number, this is only to help
        // debugging.
        let taken_ids: HashSet<_> = self.sessions.keys().collect();
        if taken_ids.is_empty() {
            Ok(MIN_SESSION_ID)
        } else {
            let max_val = **taken_ids.iter().max().unwrap() + 1;
            Ok((MIN_SESSION_ID..=max_val)
                .find(|id| !taken_ids.contains(id))
                .unwrap())
        }
    }

    fn register_active_session(&mut self, key: ConnectKey, session_id: SessionId) {
        if let Some(old_id) = self
            .active_session_id_by_connect_key
            .insert(key.clone(), session_id)
        {
            if old_id != session_id {
                self.connect_key_by_session_id.remove(&old_id);
            }
        }
        self.connect_key_by_session_id.insert(session_id, key);
    }

    /// Insert a session. When `active_connect_key` is `Some` and not a custom socket, the session
    /// is tracked for active reuse on the next `ssh_connect` to the same `(ip, port)`.
    pub fn insert(
        &mut self,
        session_id: SessionId,
        session: Mutex<SshSession>,
        active_connect_key: Option<ConnectKey>,
    ) {
        if let Some(key) = active_connect_key {
            if !key.custom_socket {
                self.register_active_session(key, session_id);
            }
        }
        self.sessions.insert(session_id, session);
    }

    /// Return an existing active session id for this connect key, if any.
    pub(crate) fn active_session_for_connect_key(&self, key: &ConnectKey) -> Option<SessionId> {
        if key.custom_socket {
            return None;
        }
        let sid = *self.active_session_id_by_connect_key.get(key)?;
        self.sessions.contains_key(&sid).then_some(sid)
    }

    pub fn remove(&mut self, session_id: SessionId) -> Result<()> {
        if let Some(key) = self.connect_key_by_session_id.remove(&session_id) {
            if self.active_session_id_by_connect_key.get(&key) == Some(&session_id) {
                self.active_session_id_by_connect_key.remove(&key);
            }
        }
        self.sessions.remove(&session_id);
        Ok(())
    }

    pub(crate) fn take_cached(&mut self, key: &ConnectKey, now: Instant) -> Option<Mutex<SshSession>> {
        self.ensure_ttl_initialized();
        if self.soft_disconnect_ttl.is_none() {
            // Non-expiring mode: always reuse if present.
            return self.cache_by_connect_key.remove(key).map(|(s, _)| s);
        }

        if let Some((_session, expires_at)) = self.cache_by_connect_key.get(key) {
            if *expires_at > now {
                // Recreate entry without holding borrow across moves.
                return self.cache_by_connect_key.remove(key).map(|(s, _)| s);
            }
        }
        // Expired or missing.
        self.cache_by_connect_key.remove(key).map(|(s, _)| s)
    }

    pub(crate) fn put_cached(&mut self, key: ConnectKey, session: Mutex<SshSession>, now: Instant) {
        self.ensure_ttl_initialized();
        let expires_at = self
            .soft_disconnect_ttl
            .map(|ttl| now + ttl)
            .unwrap_or(now + Duration::from_secs(u64::MAX / 4));
        self.cache_by_connect_key.insert(key, (session, expires_at));
    }

    /// Soft-disconnect a session: keep the underlying SSH transport alive for a short TTL.
    ///
    /// This intentionally invalidates the `session_id` (it is removed from `sessions`),
    /// so subsequent operations using the old `session_id` fail with `InvalidSessionId`.
    pub async fn disconnect_to_cache(&mut self, session_id: SessionId) -> Result<()> {
        if session_id == 0 {
            return Ok(());
        }

        let Some(session_mutex) = self.sessions.remove(&session_id) else {
            return Ok(());
        };

        if let Some(key) = self.connect_key_by_session_id.remove(&session_id) {
            if self.active_session_id_by_connect_key.get(&key) == Some(&session_id) {
                self.active_session_id_by_connect_key.remove(&key);
            }
        }

        // Lock only long enough to decide how to dispose it.
        let connect_key;
        let custom_socket;
        {
            let mut session = session_mutex.lock().await;
            custom_socket = session.custom_socket;
            if custom_socket {
                // For custom sockets we don't want to cache/reuse the transport.
                session.hard_disconnect().await?;
                return Ok(());
            }

            session.soft_disconnect().await;
            connect_key = session.connect_key.clone();
        }

        self.put_cached(connect_key, session_mutex, Instant::now());
        Ok(())
    }

    #[cfg(feature = "nasl-builtin-libssh")]
    pub fn ids(&self) -> impl Iterator<Item = &SessionId> {
        self.sessions.keys()
    }
}
