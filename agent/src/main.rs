mod api;
mod auth;
mod config;
mod notifications;
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

/// Raise the file-descriptor soft limit so everything we spawn — most
/// importantly the tmux server, and through it every session it hosts —
/// inherits a workable limit. When MacMarmy (or any GUI parent) launches the
/// agent, the inherited soft limit can be as low as 256/2560, which Claude
/// Code exhausts and dies on. Must run before the tmux controller starts.
#[cfg(unix)]
fn raise_fd_limit() {
    unsafe {
        let mut lim = libc::rlimit {
            rlim_cur: 0,
            rlim_max: 0,
        };
        if libc::getrlimit(libc::RLIMIT_NOFILE, &mut lim) != 0 {
            return;
        }
        // macOS caps the soft limit at kern.maxfilesperproc even when the
        // hard limit reports unlimited, so walk down until one sticks.
        for target in [65536, 32768, 10240 as libc::rlim_t] {
            let want = libc::rlimit {
                rlim_cur: if lim.rlim_max == libc::RLIM_INFINITY {
                    target
                } else {
                    target.min(lim.rlim_max)
                },
                rlim_max: lim.rlim_max,
            };
            if want.rlim_cur <= lim.rlim_cur {
                info!("fd limit already {} — leaving as-is", lim.rlim_cur);
                return;
            }
            if libc::setrlimit(libc::RLIMIT_NOFILE, &want) == 0 {
                info!("raised fd soft limit {} -> {}", lim.rlim_cur, want.rlim_cur);
                return;
            }
        }
        error!("failed to raise fd soft limit (still {})", lim.rlim_cur);
    }
}

#[cfg(not(unix))]
fn raise_fd_limit() {}

async fn cmd_serve(bind_override: Option<String>, port_override: Option<u16>) -> Result<()> {
    raise_fd_limit();

    let config = Config::load().context("failed to load config")?;

    let bind = bind_override.unwrap_or_else(|| config.server.bind.clone());
    let port = port_override.unwrap_or(config.server.port);

    info!("starting marmy-agent on {}:{}", bind, port);

    let socket = if config.tmux.socket_name.is_empty() {
        None
    } else {
        Some(config.tmux.socket_name.as_str())
    };

    let tmux = TmuxController::start(socket)
        .await
        .context("failed to start tmux controller")?;

    info!("tmux controller ready");

    let state = AppState::new(tmux, config.clone());

    // Rewrite notification hook if already enabled (picks up new token/port)
    api::notifications::refresh_hook_if_enabled(port, &config.auth.token);

    // Refresh topology on startup
    if let Err(e) = state.refresh_topology().await {
        error!(error = %e, "failed initial topology refresh");
    }

    // Spawn polling loop: re-query topology every 2 seconds
    let refresh_state = state.clone();
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(std::time::Duration::from_secs(2)).await;
            if let Err(e) = refresh_state.refresh_topology().await {
                error!(error = %e, "topology refresh failed");
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
    let local_ips = get_local_ips();

    println!("=== Marmy Pairing Info ===\n");
    println!("Port:      {}", config.server.port);
    println!("Token:     {}", config.auth.token);
    println!();
    if local_ips.is_empty() {
        println!("No network interfaces found. Check your connection.");
    } else {
        println!("In the Marmy app, add this machine with one of:");
        for ip in &local_ips {
            println!("  Address:  {}:{}", ip, config.server.port);
        }
    }
    println!("  Token:    {}", config.auth.token);
    println!();
    println!("Config file: {}", config::config_path().display());

    Ok(())
}

fn get_local_ips() -> Vec<String> {
    let mut ips = Vec::new();
    let Ok(interfaces) = std::net::UdpSocket::bind("0.0.0.0:0") else {
        return ips;
    };
    // Connect to a public address to determine the default route IP
    if interfaces.connect("8.8.8.8:80").is_ok() {
        if let Ok(addr) = interfaces.local_addr() {
            ips.push(addr.ip().to_string());
        }
    }
    ips
}

fn cmd_config() -> Result<()> {
    let config = Config::load()?;
    println!("{}", toml::to_string_pretty(&config)?);
    println!("# Config file: {}", config::config_path().display());
    Ok(())
}
