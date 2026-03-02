use std::sync::Arc;

use tokio::sync::{watch, RwLock};

use crate::config::Config;
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
}

pub struct AppStateInner {
    /// Cached topology, refreshed periodically.
    pub topology: Option<TmuxTopology>,
}

impl AppState {
    pub fn new(tmux: TmuxController, config: Config) -> Self {
        let (topology_tx, topology_rx) = watch::channel(None);
        Self {
            inner: Arc::new(RwLock::new(AppStateInner { topology: None })),
            tmux,
            config,
            topology_tx,
            topology_rx,
        }
    }

    /// Refresh the cached topology from tmux.
    /// Sends on the watch channel only if the topology actually changed.
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
}
