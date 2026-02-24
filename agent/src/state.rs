use std::sync::Arc;

use tokio::sync::RwLock;

use crate::config::Config;
use crate::tmux::{TmuxController, TmuxTopology};

/// Shared application state accessible from all API handlers.
#[derive(Clone)]
pub struct AppState {
    pub inner: Arc<RwLock<AppStateInner>>,
    pub tmux: TmuxController,
    pub config: Config,
}

pub struct AppStateInner {
    /// Cached topology, refreshed periodically and on topology events.
    pub topology: Option<TmuxTopology>,
}

impl AppState {
    pub fn new(tmux: TmuxController, config: Config) -> Self {
        Self {
            inner: Arc::new(RwLock::new(AppStateInner { topology: None })),
            tmux,
            config,
        }
    }

    /// Refresh the cached topology from tmux.
    pub async fn refresh_topology(&self) -> anyhow::Result<()> {
        let topology = self.tmux.get_topology().await?;
        self.inner.write().await.topology = Some(topology);
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
