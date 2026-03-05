use anyhow::{Context, Result};
use tokio::process::Command;
use tracing::{info, warn};

use super::types::{TmuxPane, TmuxSession, TmuxTopology, TmuxWindow};

/// Handle for interacting with tmux via plain subprocess calls.
///
/// Each method spawns a short-lived `tmux` process, captures its output,
/// and parses the result. No persistent pipe, no control mode, no PTY.
#[derive(Clone)]
pub struct TmuxController {
    socket_name: Option<String>,
}

impl TmuxController {
    /// Initialize the tmux controller and ensure the heartbeat session exists.
    ///
    /// The `_marmy_ctrl` session keeps the tmux server alive even when the
    /// user has no sessions of their own. It is hidden from topology queries.
    pub async fn start(socket_name: Option<&str>) -> Result<Self> {
        let controller = Self {
            socket_name: socket_name.map(|s| s.to_string()),
        };

        // Kill any stale _marmy_ctrl session from a previous run
        let _ = controller.run_tmux(&["kill-session", "-t", "_marmy_ctrl"]).await;

        // Remove CLAUDECODE from tmux's global environment so new sessions
        // created via the agent don't trigger Claude Code's nesting check.
        let _ = controller
            .run_tmux(&["set-environment", "-g", "-u", "CLAUDECODE"])
            .await;

        // Create the heartbeat session
        controller
            .run_tmux(&[
                "new-session", "-d", "-s", "_marmy_ctrl", "-x", "200", "-y", "50",
            ])
            .await
            .context("failed to create _marmy_ctrl heartbeat session")?;

        info!("tmux heartbeat session _marmy_ctrl created");
        Ok(controller)
    }

    /// Run a tmux command as a subprocess and return its stdout.
    async fn run_tmux(&self, args: &[&str]) -> Result<String> {
        let mut cmd = Command::new("tmux");
        if let Some(ref socket) = self.socket_name {
            cmd.arg("-L").arg(socket);
        }
        cmd.args(args);

        let output = cmd
            .output()
            .await
            .with_context(|| format!("failed to spawn tmux {:?}", args))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            anyhow::bail!(
                "tmux {:?} failed (exit {}): {}",
                args,
                output.status,
                stderr.trim()
            );
        }

        let stdout = String::from_utf8_lossy(&output.stdout).to_string();
        let stderr_str = String::from_utf8_lossy(&output.stderr).to_string();
        info!(args = ?args, stdout_len = stdout.len(), stdout = %stdout.trim(), stderr = %stderr_str.trim(), "run_tmux");
        Ok(stdout)
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
        let output = self
            .run_tmux(&[
                "list-sessions",
                "-F",
                "#{session_id}|||#{session_name}|||#{session_windows}|||#{session_attached}",
            ])
            .await?;

        let mut sessions: Vec<TmuxSession> = output
            .lines()
            .filter_map(parse_session_line)
            .collect();

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
        let output = self
            .run_tmux(&[
                "list-windows",
                "-a",
                "-F",
                "#{window_id}|||#{session_id}|||#{window_index}|||#{window_name}|||#{window_active}",
            ])
            .await?;

        let windows = output.lines().filter_map(parse_window_line).collect();
        Ok(windows)
    }

    pub async fn list_panes(&self) -> Result<Vec<TmuxPane>> {
        let output = self
            .run_tmux(&[
                "list-panes",
                "-a",
                "-F",
                "#{pane_id}|||#{window_id}|||#{session_id}|||#{pane_index}|||#{pane_width}|||#{pane_height}|||#{pane_active}|||#{pane_current_command}|||#{pane_current_path}|||#{pane_pid}",
            ])
            .await?;

        let panes = output.lines().filter_map(parse_pane_line).collect();
        Ok(panes)
    }

    /// Capture the current visible content of a pane.
    pub async fn capture_pane(&self, pane_id: &str, scrollback: bool) -> Result<String> {
        let mut args = vec!["capture-pane", "-t", pane_id, "-p", "-e"];
        if scrollback {
            args.push("-S");
            args.push("-");
        }
        self.run_tmux(&args).await
    }

    /// Send raw bytes to a pane using hex encoding.
    pub async fn send_bytes(&self, pane_id: &str, data: &[u8]) -> Result<()> {
        if data.is_empty() {
            return Ok(());
        }
        let hex_args: Vec<String> = data.iter().map(|b| format!("{:02X}", b)).collect();
        let mut args: Vec<&str> = vec!["send-keys", "-t", pane_id, "-H"];
        args.extend(hex_args.iter().map(|s| s.as_str()));
        let _ = self.run_tmux(&args).await;
        Ok(())
    }

    /// Send text + Enter to a pane.
    ///
    /// Uses two separate tmux invocations: one for the literal text (-l),
    /// one for the Enter key. This is needed because TUI apps don't process
    /// Enter correctly when text + CR arrive in the same PTY write.
    pub async fn send_text_enter(&self, pane_id: &str, text: &str) -> Result<()> {
        if !text.is_empty() {
            let result = self.run_tmux(&["send-keys", "-t", pane_id, "-l", text]).await;
            if let Err(e) = &result {
                warn!(error = %e, "tmux send-keys (text) failed");
            }
        }

        let result = self
            .run_tmux(&["send-keys", "-t", pane_id, "Enter"])
            .await;
        if let Err(e) = &result {
            warn!(error = %e, "tmux send-keys (Enter) failed");
        }
        Ok(())
    }

    /// Create a new tmux session.
    pub async fn new_session(&self, name: &str) -> Result<()> {
        self.run_tmux(&["new-session", "-d", "-s", name]).await?;
        Ok(())
    }

    /// Create a new tmux session with a specific working directory.
    pub async fn new_session_in_dir(&self, name: &str, dir: &str) -> Result<()> {
        self.run_tmux(&["new-session", "-d", "-s", name, "-c", dir])
            .await?;
        Ok(())
    }

    /// Set an environment variable on a tmux session.
    pub async fn set_session_env(&self, session: &str, key: &str, value: &str) -> Result<()> {
        self.run_tmux(&["set-environment", "-t", session, key, value])
            .await?;
        Ok(())
    }

    /// Kill (delete) a tmux session.
    pub async fn kill_session(&self, name: &str) -> Result<()> {
        self.run_tmux(&["kill-session", "-t", name]).await?;
        Ok(())
    }

    /// Resize a pane.
    pub async fn resize_pane(&self, pane_id: &str, cols: u32, rows: u32) -> Result<()> {
        let cols_str = cols.to_string();
        let rows_str = rows.to_string();
        self.run_tmux(&["resize-pane", "-t", pane_id, "-x", &cols_str, "-y", &rows_str])
            .await?;
        Ok(())
    }
}

// --- Pure parsing functions (testable without tmux) ---

const DELIM: &str = "|||";

fn parse_session_line(line: &str) -> Option<TmuxSession> {
    let parts: Vec<&str> = line.split(DELIM).collect();
    if parts.len() < 4 {
        return None;
    }
    // Skip the heartbeat session
    if parts[1] == "_marmy_ctrl" {
        return None;
    }
    Some(TmuxSession {
        id: parts[0].to_string(),
        name: parts[1].to_string(),
        windows: Vec::new(), // filled later by list_sessions
        attached: parts[3] != "0",
    })
}

fn parse_window_line(line: &str) -> Option<TmuxWindow> {
    let parts: Vec<&str> = line.split(DELIM).collect();
    if parts.len() < 5 {
        return None;
    }
    Some(TmuxWindow {
        id: parts[0].to_string(),
        session_id: parts[1].to_string(),
        index: parts[2].parse().unwrap_or(0),
        name: parts[3].to_string(),
        panes: Vec::new(),
        active: parts[4] != "0",
    })
}

fn parse_pane_line(line: &str) -> Option<TmuxPane> {
    let parts: Vec<&str> = line.split(DELIM).collect();
    if parts.len() < 10 {
        return None;
    }
    Some(TmuxPane {
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
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_sessions() {
        let line = "$0|||dev|||3|||1";
        let session = parse_session_line(line).unwrap();
        assert_eq!(session.id, "$0");
        assert_eq!(session.name, "dev");
        assert!(session.attached);
        assert!(session.windows.is_empty()); // filled later
    }

    #[test]
    fn test_parse_sessions_filters_marmy_ctrl() {
        let line = "$5|||_marmy_ctrl|||1|||0";
        assert!(parse_session_line(line).is_none());
    }

    #[test]
    fn test_parse_sessions_empty() {
        assert!(parse_session_line("").is_none());
    }

    #[test]
    fn test_parse_sessions_not_attached() {
        let line = "$1|||work|||2|||0";
        let session = parse_session_line(line).unwrap();
        assert_eq!(session.name, "work");
        assert!(!session.attached);
    }

    #[test]
    fn test_parse_windows() {
        let line = "@0|||$0|||0|||bash|||1";
        let window = parse_window_line(line).unwrap();
        assert_eq!(window.id, "@0");
        assert_eq!(window.session_id, "$0");
        assert_eq!(window.index, 0);
        assert_eq!(window.name, "bash");
        assert!(window.active);
    }

    #[test]
    fn test_parse_windows_inactive() {
        let line = "@3|||$1|||2|||vim|||0";
        let window = parse_window_line(line).unwrap();
        assert_eq!(window.name, "vim");
        assert!(!window.active);
    }

    #[test]
    fn test_parse_panes() {
        let line = "%0|||@0|||$0|||0|||120|||40|||1|||bash|||/home/user|||12345";
        let pane = parse_pane_line(line).unwrap();
        assert_eq!(pane.id, "%0");
        assert_eq!(pane.window_id, "@0");
        assert_eq!(pane.session_id, "$0");
        assert_eq!(pane.index, 0);
        assert_eq!(pane.width, 120);
        assert_eq!(pane.height, 40);
        assert!(pane.active);
        assert_eq!(pane.current_command, "bash");
        assert_eq!(pane.current_path, "/home/user");
        assert_eq!(pane.pid, 12345);
    }

    #[test]
    fn test_parse_malformed_lines() {
        // Too few fields — should return None, not panic
        assert!(parse_session_line("$0|||dev").is_none());
        assert!(parse_window_line("@0|||$0").is_none());
        assert!(parse_pane_line("%0|||@0|||$0|||0").is_none());
        assert!(parse_session_line("").is_none());
        assert!(parse_window_line("").is_none());
        assert!(parse_pane_line("").is_none());
    }
}
