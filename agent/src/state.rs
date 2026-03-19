use std::collections::HashSet;
use std::sync::Arc;

use tokio::sync::{watch, RwLock};

use crate::config::Config;
use crate::notifications::{self, NotificationSender, PushToken};
use crate::tmux::{TmuxController, TmuxTopology};

/// Shared application state accessible from all API handlers.
#[derive(Clone)]
pub struct AppState {
    pub inner: Arc<RwLock<AppStateInner>>,
    pub tmux: TmuxController,
    pub config: Config,
    /// Notifies WebSocket clients when topology changes.
    pub topology_tx: watch::Sender<Option<TmuxTopology>>,
    pub topology_rx: watch::Receiver<Option<TmuxTopology>>,
    /// APNs sender — called by the `/api/notifications/send` endpoint.
    pub sender: Arc<NotificationSender>,
}

pub struct AppStateInner {
    /// Cached topology, refreshed periodically.
    pub topology: Option<TmuxTopology>,
    /// Registered device push tokens with routing provider.
    pub push_tokens: Vec<PushToken>,
    /// Sessions with unread activity (task completions).
    pub unread_sessions: HashSet<String>,
}

impl AppState {
    pub fn new(tmux: TmuxController, config: Config) -> Self {
        let (topology_tx, topology_rx) = watch::channel(None);
        let push_tokens = notifications::load_push_tokens();
        let unread_sessions = notifications::load_unread_sessions();
        let sender = NotificationSender::new(&config.notifications);
        Self {
            inner: Arc::new(RwLock::new(AppStateInner {
                topology: None,
                push_tokens,
                unread_sessions,
            })),
            tmux,
            config,
            topology_tx,
            topology_rx,
            sender: Arc::new(sender),
        }
    }

    /// Refresh the cached topology from tmux.
    pub async fn refresh_topology(&self) -> anyhow::Result<()> {
        let new_topology = self.tmux.get_topology().await?;
        let mut inner = self.inner.write().await;
        let changed = inner.topology.as_ref() != Some(&new_topology);
        inner.topology = Some(new_topology.clone());
        drop(inner);

        if changed {
            let _ = self.topology_tx.send(Some(new_topology));
        }
        Ok(())
    }

    /// Get the cached topology, refreshing if stale.
    pub async fn get_topology(&self) -> anyhow::Result<TmuxTopology> {
        {
            let inner = self.inner.read().await;
            if let Some(ref topo) = inner.topology {
                return Ok(topo.clone());
            }
        }
        self.refresh_topology().await?;
        let inner = self.inner.read().await;
        Ok(inner.topology.clone().unwrap_or_else(|| TmuxTopology {
            sessions: Vec::new(),
            windows: Vec::new(),
            panes: Vec::new(),
        }))
    }

    /// Register a push token with its provider.
    pub async fn register_push_token(&self, token: String, provider: String) {
        let mut inner = self.inner.write().await;
        // Remove any existing entry for this token (provider may have changed)
        inner.push_tokens.retain(|pt| pt.token != token);
        inner.push_tokens.push(PushToken { token, provider });
        notifications::save_push_tokens(&inner.push_tokens);
    }

    /// Unregister a push token.
    pub async fn unregister_push_token(&self, token: &str) {
        let mut inner = self.inner.write().await;
        inner.push_tokens.retain(|pt| pt.token != token);
        notifications::save_push_tokens(&inner.push_tokens);
    }

    /// Get all registered push tokens.
    pub async fn get_push_tokens(&self) -> Vec<PushToken> {
        let inner = self.inner.read().await;
        inner.push_tokens.clone()
    }

    /// Mark a session as having unread activity. Persists and re-broadcasts topology.
    pub async fn mark_session_unread(&self, name: String) {
        let mut inner = self.inner.write().await;
        if inner.unread_sessions.insert(name) {
            notifications::save_unread_sessions(&inner.unread_sessions);
            // Re-broadcast topology so connected clients see the change
            if let Some(ref topo) = inner.topology {
                let _ = self.topology_tx.send(Some(topo.clone()));
            }
        }
    }

    /// Clear unread state for a session. Persists and re-broadcasts topology.
    pub async fn mark_session_read(&self, name: &str) {
        let mut inner = self.inner.write().await;
        if inner.unread_sessions.remove(name) {
            notifications::save_unread_sessions(&inner.unread_sessions);
            if let Some(ref topo) = inner.topology {
                let _ = self.topology_tx.send(Some(topo.clone()));
            }
        }
    }

    /// Get the set of unread session names.
    pub async fn get_unread_sessions(&self) -> HashSet<String> {
        let inner = self.inner.read().await;
        inner.unread_sessions.clone()
    }
}
