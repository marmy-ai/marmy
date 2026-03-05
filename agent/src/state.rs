use std::sync::Arc;

use tokio::sync::{watch, RwLock};

use crate::config::Config;
use crate::notifications::{self, NotificationSender};
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
    /// Registered device push tokens (raw APNs tokens).
    pub push_tokens: Vec<String>,
}

impl AppState {
    pub fn new(tmux: TmuxController, config: Config) -> Self {
        let (topology_tx, topology_rx) = watch::channel(None);
        let push_tokens = notifications::load_push_tokens();
        let sender = NotificationSender::new(&config.notifications);
        Self {
            inner: Arc::new(RwLock::new(AppStateInner {
                topology: None,
                push_tokens,
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

    /// Register a push token.
    pub async fn register_push_token(&self, token: String) {
        let mut inner = self.inner.write().await;
        if !inner.push_tokens.contains(&token) {
            inner.push_tokens.push(token);
            notifications::save_push_tokens(&inner.push_tokens);
        }
    }

    /// Unregister a push token.
    pub async fn unregister_push_token(&self, token: &str) {
        let mut inner = self.inner.write().await;
        inner.push_tokens.retain(|t| t != token);
        notifications::save_push_tokens(&inner.push_tokens);
    }

    /// Get all registered push tokens.
    pub async fn get_push_tokens(&self) -> Vec<String> {
        let inner = self.inner.read().await;
        inner.push_tokens.clone()
    }
}
