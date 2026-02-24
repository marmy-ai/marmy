mod api;
mod auth;
mod config;
mod state;
mod tmux;

use std::net::SocketAddr;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use tracing::{error, info};

use config::Config;
use state::AppState;
use tmux::TmuxController;

#[derive(Parser)]
#[command(name = "marmy-agent", about = "Marmy agent daemon — bridges tmux to mobile")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Start the agent daemon
    Serve {
        /// Override bind address
        #[arg(short, long)]
        bind: Option<String>,
        /// Override port
        #[arg(short, long)]
        port: Option<u16>,
    },
    /// Show pairing info (token and connection details)
    Pair,
    /// Show current configuration
    Config,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "marmy_agent=info".into()),
        )
        .init();

    let cli = Cli::parse();

    match cli.command {
        Commands::Serve { bind, port } => cmd_serve(bind, port).await,
        Commands::Pair => cmd_pair(),
        Commands::Config => cmd_config(),
    }
}

async fn cmd_serve(bind_override: Option<String>, port_override: Option<u16>) -> Result<()> {
    let config = Config::load().context("failed to load config")?;

    let bind = bind_override.unwrap_or_else(|| config.server.bind.clone());
    let port = port_override.unwrap_or(config.server.port);

    info!("starting marmy-agent on {}:{}", bind, port);

    // Connect to tmux via control mode
    let socket = if config.tmux.socket_name.is_empty() {
        None
    } else {
        Some(config.tmux.socket_name.as_str())
    };

    let (tmux, mut event_rx) = TmuxController::start(socket)
        .await
        .context("failed to start tmux control mode")?;

    info!("connected to tmux control mode");

    let state = AppState::new(tmux, config.clone());

    // Refresh topology on startup
    if let Err(e) = state.refresh_topology().await {
        error!(error = %e, "failed initial topology refresh");
    }

    // Spawn topology refresh task: re-query on topology change events
    let refresh_state = state.clone();
    tokio::spawn(async move {
        loop {
            match event_rx.recv().await {
                Ok(tmux::TmuxEvent::SessionsChanged)
                | Ok(tmux::TmuxEvent::WindowAdd { .. })
                | Ok(tmux::TmuxEvent::WindowClose { .. }) => {
                    // Small delay to let tmux settle
                    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                    if let Err(e) = refresh_state.refresh_topology().await {
                        error!(error = %e, "topology refresh failed");
                    }
                }
                Ok(_) => {}
                Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                    tracing::warn!(count = n, "topology listener lagged");
                }
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            }
        }
    });

    // Build and start the HTTP server
    let app = api::build_router(state);
    let addr: SocketAddr = format!("{}:{}", bind, port)
        .parse()
        .context("invalid bind address")?;

    info!("listening on {}", addr);
    info!(
        "pair with token: {}",
        if config.auth.token.len() > 8 {
            format!("{}...", &config.auth.token[..8])
        } else {
            config.auth.token.clone()
        }
    );

    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
}

fn cmd_pair() -> Result<()> {
    let config = Config::load()?;
    let hostname = hostname::get()
        .map(|h| h.to_string_lossy().to_string())
        .unwrap_or_else(|_| "unknown".to_string());

    println!("=== Marmy Pairing Info ===\n");
    println!("Hostname:  {}", hostname);
    println!("Port:      {}", config.server.port);
    println!("Token:     {}", config.auth.token);
    println!();
    println!("In the Marmy app, add this machine with:");
    println!("  Address:  {}:{}", hostname, config.server.port);
    println!("  Token:    {}", config.auth.token);
    println!();
    println!("If using Tailscale, use your Tailscale IP or MagicDNS hostname.");
    println!("Config file: {}", config::config_path().display());

    Ok(())
}

fn cmd_config() -> Result<()> {
    let config = Config::load()?;
    println!("{}", toml::to_string_pretty(&config)?);
    println!("# Config file: {}", config::config_path().display());
    Ok(())
}
