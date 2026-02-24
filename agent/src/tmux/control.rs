use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use anyhow::{Context, Result};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::{broadcast, mpsc, oneshot, Mutex};
use tracing::{debug, error, info, warn};

use super::parser::{ControlParser, ParsedLine};
use super::types::{CommandResult, TmuxEvent, TmuxPane, TmuxSession, TmuxTopology, TmuxWindow};

/// Handle for sending commands to the tmux control mode connection.
#[derive(Clone)]
pub struct TmuxController {
    cmd_tx: mpsc::Sender<TmuxCommand>,
    event_tx: broadcast::Sender<TmuxEvent>,
    command_counter: Arc<AtomicU64>,
    pending: Arc<Mutex<HashMap<u64, oneshot::Sender<CommandResult>>>>,
}

struct TmuxCommand {
    command: String,
}

impl TmuxController {
    /// Spawn a tmux control mode client and return a controller handle.
    ///
    /// Uses `tmux -CC new-session -A -s _marmy` which attaches to the
    /// `_marmy` session if it exists, or creates it. This session acts
    /// as the control channel — the agent sees events from ALL sessions.
    pub async fn start(socket_name: Option<&str>) -> Result<(Self, broadcast::Receiver<TmuxEvent>)>
    {
        let mut cmd = Command::new("tmux");

        if let Some(socket) = socket_name {
            cmd.arg("-L").arg(socket);
        }

        cmd.args(["-CC", "new-session", "-A", "-s", "_marmy_ctrl", "-x", "200", "-y", "50"]);
        cmd.stdin(std::process::Stdio::piped());
        cmd.stdout(std::process::Stdio::piped());
        cmd.stderr(std::process::Stdio::null());

        let mut child = cmd.spawn().context("failed to spawn tmux -CC")?;

        let stdin = child.stdin.take().context("no stdin on tmux process")?;
        let stdout = child.stdout.take().context("no stdout on tmux process")?;

        let (event_tx, event_rx) = broadcast::channel(4096);
        let (cmd_tx, cmd_rx) = mpsc::channel::<TmuxCommand>(256);
        let pending: Arc<Mutex<HashMap<u64, oneshot::Sender<CommandResult>>>> =
            Arc::new(Mutex::new(HashMap::new()));
        let command_counter = Arc::new(AtomicU64::new(1));

        let controller = Self {
            cmd_tx,
            event_tx: event_tx.clone(),
            command_counter,
            pending: pending.clone(),
        };

        // Spawn reader task: reads stdout, parses control mode protocol
        let reader_pending = pending.clone();
        let reader_event_tx = event_tx.clone();
        tokio::spawn(async move {
            Self::reader_loop(stdout, reader_pending, reader_event_tx).await;
            info!("tmux reader loop exited");
        });

        // Spawn writer task: receives commands from channel, writes to stdin
        tokio::spawn(async move {
            Self::writer_loop(stdin, cmd_rx, pending).await;
            info!("tmux writer loop exited");
        });

        // Keep child process handle alive
        tokio::spawn(async move {
            Self::child_waiter(child).await;
        });

        Ok((controller, event_rx))
    }

    /// Send a command to tmux and wait for the response.
    pub async fn command(&self, command: &str) -> Result<CommandResult> {
        let cmd_num = self.command_counter.fetch_add(1, Ordering::SeqCst);
        let (response_tx, response_rx) = oneshot::channel();

        // Register the pending response handler (reader task will resolve it)
        self.pending.lock().await.insert(cmd_num, response_tx);

        // Send command text to the writer task
        let _ = self.cmd_tx.send(TmuxCommand {
            command: command.to_string(),
        }).await;

        let result = response_rx
            .await
            .context("tmux command response channel closed")?;
        Ok(result)
    }

    /// Send a command without waiting for a response (fire-and-forget).
    pub async fn command_fire(&self, command: &str) -> Result<()> {
        let _cmd_num = self.command_counter.fetch_add(1, Ordering::SeqCst);
        // Don't register in pending — response will be dropped
        let _ = self.cmd_tx.send(TmuxCommand {
            command: command.to_string(),
        }).await;
        Ok(())
    }

    /// Subscribe to tmux events.
    pub fn subscribe(&self) -> broadcast::Receiver<TmuxEvent> {
        self.event_tx.subscribe()
    }

    /// Query full topology: all sessions, windows, panes.
    pub async fn get_topology(&self) -> Result<TmuxTopology> {
        let sessions = self.list_sessions().await?;
        let windows = self.list_windows().await?;
        let panes = self.list_panes().await?;
        Ok(TmuxTopology {
            sessions,
            windows,
            panes,
        })
    }

    pub async fn list_sessions(&self) -> Result<Vec<TmuxSession>> {
        let result = self
            .command("list-sessions -F '#{session_id}\t#{session_name}\t#{session_windows}\t#{session_attached}'")
            .await?;

        let mut sessions = Vec::new();
        for line in &result.lines {
            let parts: Vec<&str> = line.split('\t').collect();
            if parts.len() >= 4 {
                // Skip our control session
                if parts[1] == "_marmy_ctrl" {
                    continue;
                }
                sessions.push(TmuxSession {
                    id: parts[0].to_string(),
                    name: parts[1].to_string(),
                    windows: Vec::new(), // filled below
                    attached: parts[3] != "0",
                });
            }
        }

        // Fill window IDs per session
        let windows = self.list_windows().await?;
        for session in &mut sessions {
            session.windows = windows
                .iter()
                .filter(|w| w.session_id == session.id)
                .map(|w| w.id.clone())
                .collect();
        }

        Ok(sessions)
    }

    pub async fn list_windows(&self) -> Result<Vec<TmuxWindow>> {
        let result = self
            .command("list-windows -a -F '#{window_id}\t#{session_id}\t#{window_index}\t#{window_name}\t#{window_active}'")
            .await?;

        let mut windows = Vec::new();
        for line in &result.lines {
            let parts: Vec<&str> = line.split('\t').collect();
            if parts.len() >= 5 {
                windows.push(TmuxWindow {
                    id: parts[0].to_string(),
                    session_id: parts[1].to_string(),
                    index: parts[2].parse().unwrap_or(0),
                    name: parts[3].to_string(),
                    panes: Vec::new(), // filled by list_panes
                    active: parts[4] != "0",
                });
            }
        }

        Ok(windows)
    }

    pub async fn list_panes(&self) -> Result<Vec<TmuxPane>> {
        let result = self
            .command("list-panes -a -F '#{pane_id}\t#{window_id}\t#{session_id}\t#{pane_index}\t#{pane_width}\t#{pane_height}\t#{pane_active}\t#{pane_current_command}\t#{pane_current_path}\t#{pane_pid}'")
            .await?;

        let mut panes = Vec::new();
        for line in &result.lines {
            let parts: Vec<&str> = line.split('\t').collect();
            if parts.len() >= 10 {
                panes.push(TmuxPane {
                    id: parts[0].to_string(),
                    window_id: parts[1].to_string(),
                    session_id: parts[2].to_string(),
                    index: parts[3].parse().unwrap_or(0),
                    width: parts[4].parse().unwrap_or(80),
                    height: parts[5].parse().unwrap_or(24),
                    active: parts[6] != "0",
                    current_command: parts[7].to_string(),
                    current_path: parts[8].to_string(),
                    pid: parts[9].parse().unwrap_or(0),
                });
            }
        }

        Ok(panes)
    }

    /// Capture the current visible content of a pane.
    pub async fn capture_pane(&self, pane_id: &str, scrollback: bool) -> Result<String> {
        let flag = if scrollback { " -S -" } else { "" };
        let cmd = format!("capture-pane -t {} -p -e{}", pane_id, flag);
        let result = self.command(&cmd).await?;
        Ok(result.lines.join("\n"))
    }

    /// Send keys to a pane.
    pub async fn send_keys(&self, pane_id: &str, keys: &str) -> Result<()> {
        // Use -l for literal text to avoid key name interpretation
        let cmd = format!("send-keys -t {} -l {}", pane_id, shell_quote(keys));
        self.command_fire(&cmd).await
    }

    /// Send special key (Enter, C-c, etc.) to a pane.
    pub async fn send_special_key(&self, pane_id: &str, key: &str) -> Result<()> {
        let cmd = format!("send-keys -t {} {}", pane_id, key);
        self.command_fire(&cmd).await
    }

    /// Resize a pane.
    pub async fn resize_pane(&self, pane_id: &str, cols: u32, rows: u32) -> Result<()> {
        let cmd = format!("resize-pane -t {} -x {} -y {}", pane_id, cols, rows);
        self.command_fire(&cmd).await
    }

    // --- Internal tasks ---

    async fn reader_loop(
        stdout: tokio::process::ChildStdout,
        pending: Arc<Mutex<HashMap<u64, oneshot::Sender<CommandResult>>>>,
        event_tx: broadcast::Sender<TmuxEvent>,
    ) {
        let mut reader = BufReader::new(stdout).lines();
        let mut parser = ControlParser::new();

        while let Ok(Some(line)) = reader.next_line().await {
            debug!(line = %line, "tmux output");

            match parser.parse_line(&line) {
                ParsedLine::Event(event) => {
                    if event_tx.send(event).is_err() {
                        debug!("no event subscribers");
                    }
                }
                ParsedLine::CommandResponse { cmd_num, result } => {
                    let mut pending = pending.lock().await;
                    if let Some(tx) = pending.remove(&cmd_num) {
                        let _ = tx.send(result);
                    }
                }
                ParsedLine::Partial => {}
            }
        }

        warn!("tmux stdout stream ended");
    }

    async fn writer_loop(
        mut stdin: tokio::process::ChildStdin,
        mut cmd_rx: mpsc::Receiver<TmuxCommand>,
        _pending: Arc<Mutex<HashMap<u64, oneshot::Sender<CommandResult>>>>,
    ) {
        while let Some(cmd) = cmd_rx.recv().await {
            let line = format!("{}\n", cmd.command);
            if let Err(e) = stdin.write_all(line.as_bytes()).await {
                error!(error = %e, "failed to write to tmux stdin");
                break;
            }
            if let Err(e) = stdin.flush().await {
                error!(error = %e, "failed to flush tmux stdin");
                break;
            }
            debug!(cmd = %cmd.command, "sent to tmux");
        }

        warn!("tmux command channel closed");
    }

    async fn child_waiter(mut child: Child) {
        match child.wait().await {
            Ok(status) => info!(status = %status, "tmux process exited"),
            Err(e) => error!(error = %e, "error waiting for tmux process"),
        }
    }
}

/// Simple shell quoting for tmux send-keys.
fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}
