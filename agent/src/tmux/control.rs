use std::collections::VecDeque;
use std::sync::Arc;

use anyhow::{Context, Result};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::process::{Child, ChildStdout, Command};
use tokio::sync::{broadcast, oneshot, Mutex};
use tracing::{debug, error, info, warn};

use super::parser::{self, ControlParser, ParsedLine};
use super::types::{CommandResult, TmuxEvent, TmuxPane, TmuxSession, TmuxTopology, TmuxWindow};

/// Internal state shared between command senders: the pending response queue
/// AND the stdin writer. Holding a single lock across both ensures the queue
/// order always matches the order commands arrive at tmux.
struct ControlInner {
    pending: VecDeque<Option<oneshot::Sender<CommandResult>>>,
    stdin: tokio::process::ChildStdin,
}

/// Handle for sending commands to the tmux control mode connection.
#[derive(Clone)]
pub struct TmuxController {
    inner: Arc<Mutex<ControlInner>>,
    event_tx: broadcast::Sender<TmuxEvent>,
    /// tmux socket name for direct command spawning. None = default server.
    socket_name: Option<String>,
}

impl TmuxController {
    /// Spawn a tmux control mode client and return a controller handle.
    ///
    /// Uses `tmux -CC new-session -A -s _marmy_ctrl` which attaches to the
    /// `_marmy_ctrl` session if it exists, or creates it. This session acts
    /// as the control channel — the agent sees events from ALL sessions.
    pub async fn start(socket_name: Option<&str>) -> Result<(Self, broadcast::Receiver<TmuxEvent>)>
    {
        // Kill any stale _marmy_ctrl session from a previous run
        let mut kill_cmd = std::process::Command::new("tmux");
        if let Some(socket) = socket_name {
            kill_cmd.arg("-L").arg(socket);
        }
        let _ = kill_cmd.args(["kill-session", "-t", "_marmy_ctrl"]).output();

        // Remove CLAUDECODE from tmux's global environment so new sessions
        // created via the agent don't trigger Claude Code's nesting check.
        let mut env_cmd = std::process::Command::new("tmux");
        if let Some(socket) = socket_name {
            env_cmd.arg("-L").arg(socket);
        }
        let _ = env_cmd.args(["set-environment", "-g", "-u", "CLAUDECODE"]).output();

        // tmux -CC (control mode) requires a PTY even when using piped stdio.
        // Wrap with `script` to allocate a pseudo-TTY.
        let mut tmux_args = vec!["tmux".to_string()];
        if let Some(socket) = socket_name {
            tmux_args.push("-L".into());
            tmux_args.push(socket.to_string());
        }
        tmux_args.extend(
            ["-CC", "new-session", "-A", "-s", "_marmy_ctrl", "-x", "200", "-y", "50"]
                .iter()
                .map(|s| s.to_string()),
        );

        let mut cmd = Command::new("script");
        if cfg!(target_os = "macos") {
            // macOS: script -q /dev/null command [args...]
            cmd.arg("-q").arg("/dev/null").args(&tmux_args);
        } else {
            // Linux: script -qc "command args..." /dev/null
            cmd.arg("-qc").arg(tmux_args.join(" ")).arg("/dev/null");
        }

        cmd.stdin(std::process::Stdio::piped());
        cmd.stdout(std::process::Stdio::piped());
        cmd.stderr(std::process::Stdio::null());

        let mut child = cmd.spawn().context("failed to spawn tmux -CC")?;

        let stdin = child.stdin.take().context("no stdin on tmux process")?;
        let stdout = child.stdout.take().context("no stdout on tmux process")?;

        let mut reader = BufReader::new(stdout).lines();

        // Consume the initial welcome %begin/%end block from tmux control mode.
        Self::consume_welcome(&mut reader).await?;

        let (event_tx, event_rx) = broadcast::channel(4096);

        let inner = Arc::new(Mutex::new(ControlInner {
            pending: VecDeque::new(),
            stdin,
        }));

        let controller = Self {
            inner: inner.clone(),
            event_tx: event_tx.clone(),
            socket_name: socket_name.map(|s| s.to_string()),
        };

        // Spawn reader task: reads stdout, parses control mode protocol
        let reader_inner = inner.clone();
        let reader_event_tx = event_tx.clone();
        tokio::spawn(async move {
            Self::reader_loop(reader, reader_inner, reader_event_tx).await;
            info!("tmux reader loop exited");
        });

        // Keep child process handle alive
        tokio::spawn(async move {
            Self::child_waiter(child).await;
        });

        Ok((controller, event_rx))
    }

    /// Consume the initial welcome block (%begin/%end) from tmux control mode.
    async fn consume_welcome(reader: &mut Lines<BufReader<ChildStdout>>) -> Result<()> {
        let mut in_block = false;

        loop {
            let raw = reader
                .next_line()
                .await
                .context("reading tmux welcome")?
                .context("tmux stdout closed during welcome")?;

            // During welcome, only protocol lines matter — strip PTY noise.
            let line = if raw.starts_with('%') {
                raw.as_str()
            } else if let Some(idx) = raw.find('%') {
                &raw[idx..]
            } else {
                raw.as_str()
            };
            debug!(line = %line, "tmux welcome");

            if !in_block {
                if line.starts_with("%begin ") {
                    in_block = true;
                }
            } else if line.starts_with("%end ") || line.starts_with("%error ") {
                info!("consumed tmux welcome block");
                return Ok(());
            }
        }
    }

    /// Send a command to tmux and wait for the response.
    ///
    /// The pending queue push and stdin write are done under a single lock
    /// so that the queue order always matches the command arrival order at tmux.
    pub async fn command(&self, command: &str) -> Result<CommandResult> {
        let (response_tx, response_rx) = oneshot::channel();

        {
            let mut inner = self.inner.lock().await;
            inner.pending.push_back(Some(response_tx));
            let line = format!("{}\n", command);
            inner
                .stdin
                .write_all(line.as_bytes())
                .await
                .context("failed to write command to tmux")?;
            inner
                .stdin
                .flush()
                .await
                .context("failed to flush tmux stdin")?;
        }

        debug!(cmd = %command, "sent to tmux (awaiting response)");

        let result = response_rx
            .await
            .context("tmux command response channel closed")?;
        Ok(result)
    }

    /// Send a command without waiting for a response (fire-and-forget).
    pub async fn command_fire(&self, command: &str) -> Result<()> {
        let mut inner = self.inner.lock().await;
        inner.pending.push_back(None);
        let line = format!("{}\n", command);
        inner
            .stdin
            .write_all(line.as_bytes())
            .await
            .context("failed to write command to tmux")?;
        inner
            .stdin
            .flush()
            .await
            .context("failed to flush tmux stdin")?;
        drop(inner);

        debug!(cmd = %command, "sent to tmux (fire-and-forget)");
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

    /// Capture the current visible content of a pane (plain text, no ANSI).
    pub async fn capture_pane(&self, pane_id: &str, scrollback: bool) -> Result<String> {
        let flag = if scrollback { " -S -" } else { "" };
        let cmd = format!("capture-pane -t {} -p{}", pane_id, flag);
        let result = self.command(&cmd).await?;
        Ok(result.lines.join("\n"))
    }

    /// Send raw bytes to a pane using hex encoding.
    /// Use this for control characters and escape sequences (Ctrl-C, Tab,
    /// arrow keys, etc.) that DON'T involve Enter/submit.
    pub async fn send_bytes(&self, pane_id: &str, data: &[u8]) -> Result<()> {
        if data.is_empty() {
            return Ok(());
        }
        let hex: String = data.iter().map(|b| format!("{:02X}", b)).collect::<Vec<_>>().join(" ");
        let cmd = format!("send-keys -t {} -H {}", pane_id, hex);
        self.command_fire(&cmd).await
    }

    /// Send text + Enter to a pane by spawning a real `tmux send-keys` process.
    /// This bypasses control mode entirely and matches the exact command format
    /// proven to work: `tmux send-keys -t <pane> "text" Enter`
    ///
    /// Direct process spawn is needed because TUI apps (like Claude Code)
    /// don't process Enter correctly when text + CR arrive in the same PTY
    /// write (which happens with control mode's send-keys -H).
    pub async fn send_text_enter(&self, pane_id: &str, text: &str) -> Result<()> {
        let mut cmd = Command::new("tmux");
        if let Some(ref socket) = self.socket_name {
            cmd.arg("-L").arg(socket);
        }
        cmd.arg("send-keys").arg("-t").arg(pane_id);
        if !text.is_empty() {
            // -l ensures text is treated as literal characters, not key names
            cmd.arg("-l").arg(text);
        }
        // Spawn a SEPARATE send-keys for Enter (can't mix -l with key names)
        let output = cmd.output().await.context("failed to spawn tmux send-keys")?;
        if !output.status.success() {
            warn!(stderr = %String::from_utf8_lossy(&output.stderr), "tmux send-keys (text) failed");
        }

        // Now send Enter as a separate tmux invocation
        let mut enter_cmd = Command::new("tmux");
        if let Some(ref socket) = self.socket_name {
            enter_cmd.arg("-L").arg(socket);
        }
        enter_cmd.arg("send-keys").arg("-t").arg(pane_id).arg("Enter");
        let output = enter_cmd.output().await.context("failed to spawn tmux send-keys Enter")?;
        if !output.status.success() {
            warn!(stderr = %String::from_utf8_lossy(&output.stderr), "tmux send-keys (Enter) failed");
        }
        Ok(())
    }

    /// Create a new tmux session.
    pub async fn new_session(&self, name: &str) -> Result<()> {
        let mut cmd = Command::new("tmux");
        if let Some(ref socket) = self.socket_name {
            cmd.arg("-L").arg(socket);
        }
        cmd.arg("new-session").arg("-d").arg("-s").arg(name);
        let output = cmd.output().await.context("failed to spawn tmux new-session")?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            anyhow::bail!("tmux new-session failed: {}", stderr.trim());
        }
        Ok(())
    }

    /// Kill (delete) a tmux session.
    pub async fn kill_session(&self, name: &str) -> Result<()> {
        let mut cmd = Command::new("tmux");
        if let Some(ref socket) = self.socket_name {
            cmd.arg("-L").arg(socket);
        }
        cmd.arg("kill-session").arg("-t").arg(name);
        let output = cmd.output().await.context("failed to spawn tmux kill-session")?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            anyhow::bail!("tmux kill-session failed: {}", stderr.trim());
        }
        Ok(())
    }

    /// Switch the control client to a target session so that %output
    /// notifications flow for that session's panes.
    pub async fn switch_client_to_session(&self, session_id: &str) -> Result<()> {
        let cmd = format!("switch-client -t {}", session_id);
        self.command_fire(&cmd).await
    }

    /// Resize a pane.
    pub async fn resize_pane(&self, pane_id: &str, cols: u32, rows: u32) -> Result<()> {
        let cmd = format!("resize-pane -t {} -x {} -y {}", pane_id, cols, rows);
        self.command_fire(&cmd).await
    }

    // --- Internal tasks ---

    async fn reader_loop(
        mut reader: Lines<BufReader<ChildStdout>>,
        inner: Arc<Mutex<ControlInner>>,
        event_tx: broadcast::Sender<TmuxEvent>,
    ) {
        let mut parser = ControlParser::new();

        while let Ok(Some(raw_line)) = reader.next_line().await {
            debug!(line = %raw_line, "tmux output");

            // Pass raw line to parser — it handles sanitization contextually
            // (strips PTY noise for protocol lines, preserves raw content)
            match parser.parse_line(&raw_line) {
                ParsedLine::Event(event) => {
                    if event_tx.send(event).is_err() {
                        debug!("no event subscribers");
                    }
                }
                ParsedLine::CommandResponse { cmd_num: _, result } => {
                    let mut guard = inner.lock().await;
                    if let Some(entry) = guard.pending.pop_front() {
                        drop(guard); // Release lock before sending on oneshot
                        if let Some(tx) = entry {
                            let _ = tx.send(result);
                        }
                        // None = fire-and-forget, response discarded
                    } else {
                        drop(guard);
                        debug!("command response with no pending handler");
                    }
                }
                ParsedLine::Partial => {}
            }
        }

        warn!("tmux stdout stream ended");
    }

    async fn child_waiter(mut child: Child) {
        match child.wait().await {
            Ok(status) => info!(status = %status, "tmux process exited"),
            Err(e) => error!(error = %e, "error waiting for tmux process"),
        }
    }
}
