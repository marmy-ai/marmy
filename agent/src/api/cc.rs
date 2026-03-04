use std::path::PathBuf;

use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};
use serde::{Deserialize, Serialize};
use tracing::info;

use crate::state::AppState;

// --- Types ---

/// A live Claude Code session derived from tmux topology.
#[derive(Debug, Serialize)]
pub struct CcSession {
    /// tmux session name (e.g. "marmy", "guitarGrail")
    pub session_name: String,
    /// tmux pane ID (e.g. "%9")
    pub pane_id: String,
    /// Working directory of the pane
    pub project_path: String,
    /// The current command running (e.g. "2.1.63" for claude)
    pub current_command: String,
}

#[derive(Debug, Serialize)]
pub struct CcSessionContext {
    pub pane_id: String,
    /// Live terminal content from the pane
    pub pane_content: String,
    /// Last 5 user inputs from the JSONL conversation log (if found)
    pub last_user_inputs: Vec<String>,
    /// Last assistant text output from the JSONL conversation log (if found)
    pub last_assistant_output: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct DashboardStartResponse {
    pub pane_id: String,
    pub session_name: String,
}

/// Wrapper for the sessions-index.json file format.
#[derive(Debug, Deserialize)]
struct SessionIndexFile {
    #[serde(default)]
    entries: Vec<SessionIndexEntry>,
}

/// Entry from Claude's sessions-index.json file.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SessionIndexEntry {
    #[serde(default)]
    #[allow(dead_code)]
    session_id: String,
    #[serde(default)]
    full_path: String,
    #[serde(default)]
    project_path: String,
}

// --- Handlers ---

/// GET /api/cc/sessions
/// Returns all live tmux panes that are running Claude Code.
/// This is tmux-first: we look at what's actually running, not historical logs.
pub async fn list_sessions(
    State(state): State<AppState>,
) -> Result<Json<Vec<CcSession>>, (StatusCode, String)> {
    let topology = state
        .get_topology()
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    let sessions: Vec<CcSession> = topology
        .panes
        .iter()
        .filter(|p| {
            // Find panes running claude — the current_command is the claude version string
            // or contains "claude". Exclude the sessions-manager itself.
            let is_claude = p.current_command.contains("claude")
                || p.current_command.chars().next().map_or(false, |c| c.is_ascii_digit());
            let session_name = topology
                .sessions
                .iter()
                .find(|s| s.id == p.session_id)
                .map(|s| s.name.as_str())
                .unwrap_or("");
            is_claude && session_name != "sessions-manager" && session_name != "_marmy_ctrl"
        })
        .filter_map(|p| {
            let session_name = topology
                .sessions
                .iter()
                .find(|s| s.id == p.session_id)?
                .name
                .clone();
            Some(CcSession {
                session_name,
                pane_id: p.id.clone(),
                project_path: p.current_path.clone(),
                current_command: p.current_command.clone(),
            })
        })
        .collect();

    Ok(Json(sessions))
}

/// GET /api/cc/sessions/:pane_id/context
/// Returns live pane content + conversation history from the JSONL log (if found).
/// The :pane_id is the tmux pane ID (without the % prefix, as with other pane endpoints).
pub async fn get_session_context(
    State(state): State<AppState>,
    Path(pane_id): Path<String>,
) -> Result<Json<CcSessionContext>, (StatusCode, String)> {
    let full_pane_id = if pane_id.starts_with('%') {
        pane_id.clone()
    } else {
        format!("%{}", pane_id)
    };

    // Get live pane content
    let pane_content = state
        .tmux
        .capture_pane(&full_pane_id, false)
        .await
        .unwrap_or_default();

    // Find the pane's working directory from topology
    let topology = state
        .get_topology()
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    let project_path = topology
        .panes
        .iter()
        .find(|p| p.id == full_pane_id)
        .map(|p| p.current_path.clone())
        .unwrap_or_default();

    // Try to find JSONL conversation log by matching project_path to sessions-index
    let (last_user_inputs, last_assistant_output) = if !project_path.is_empty() {
        find_conversation_context(&project_path)
    } else {
        (vec![], None)
    };

    Ok(Json(CcSessionContext {
        pane_id: full_pane_id,
        pane_content,
        last_user_inputs,
        last_assistant_output,
    }))
}

/// Search sessions-index files to find the most recent conversation for a project path,
/// then extract the last 5 user inputs and last assistant output.
fn find_conversation_context(project_path: &str) -> (Vec<String>, Option<String>) {
    let home = match dirs::home_dir() {
        Some(h) => h,
        None => return (vec![], None),
    };

    let claude_projects = home.join(".claude").join("projects");
    if !claude_projects.exists() {
        return (vec![], None);
    }

    // Find the most recently modified JSONL for this project path
    let mut best_path: Option<PathBuf> = None;
    let mut best_mtime: u64 = 0;

    let dirs = match std::fs::read_dir(&claude_projects) {
        Ok(d) => d,
        Err(_) => return (vec![], None),
    };

    for dir_entry in dirs.flatten() {
        let index_path = dir_entry.path().join("sessions-index.json");
        if !index_path.exists() {
            continue;
        }
        let content = match std::fs::read_to_string(&index_path) {
            Ok(c) => c,
            Err(_) => continue,
        };
        let parsed: SessionIndexFile = match serde_json::from_str(&content) {
            Ok(v) => v,
            Err(_) => continue,
        };
        for entry in &parsed.entries {
            if entry.project_path == project_path && !entry.full_path.is_empty() {
                let mtime = std::fs::metadata(&entry.full_path)
                    .and_then(|m| m.modified())
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e)))
                    .map(|d| d.as_secs())
                    .unwrap_or(0);
                if mtime > best_mtime {
                    best_mtime = mtime;
                    best_path = Some(PathBuf::from(&entry.full_path));
                }
            }
        }
    }

    let jsonl_path = match best_path {
        Some(p) if p.exists() => p,
        _ => return (vec![], None),
    };

    parse_jsonl_context(&jsonl_path)
}

/// Parse a JSONL conversation file, extracting user inputs and last assistant output.
fn parse_jsonl_context(path: &PathBuf) -> (Vec<String>, Option<String>) {
    let content = match std::fs::read_to_string(path) {
        Ok(c) => c,
        Err(_) => return (vec![], None),
    };

    let mut user_inputs: Vec<String> = Vec::new();
    let mut last_assistant_output: Option<String> = None;

    for line in content.lines() {
        let val: serde_json::Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };

        let msg_type = val.get("type").and_then(|t| t.as_str()).unwrap_or("");

        if msg_type == "user" {
            if let Some(text) = val
                .get("message")
                .and_then(|m| m.get("content"))
                .and_then(|c| c.as_str())
            {
                user_inputs.push(text.to_string());
            }
        } else if msg_type == "assistant" {
            if let Some(content_array) = val
                .get("message")
                .and_then(|m| m.get("content"))
                .and_then(|c| c.as_array())
            {
                let texts: Vec<&str> = content_array
                    .iter()
                    .filter_map(|block| {
                        if block.get("type").and_then(|t| t.as_str()) == Some("text") {
                            block.get("text").and_then(|t| t.as_str())
                        } else {
                            None
                        }
                    })
                    .collect();
                if !texts.is_empty() {
                    last_assistant_output = Some(texts.join("\n"));
                }
            }
        }
    }

    let last_user_inputs: Vec<String> = user_inputs
        .into_iter()
        .rev()
        .take(5)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect();

    (last_user_inputs, last_assistant_output)
}

/// POST /api/cc/dashboard/start
/// Creates (or reuses) a "sessions-manager" tmux session running Claude Code
/// with a CLAUDE.md that documents the marmy API endpoints.
pub async fn start_dashboard(
    State(state): State<AppState>,
) -> Result<Json<DashboardStartResponse>, (StatusCode, String)> {
    let session_name = "sessions-manager";

    // Check if session already exists
    let topology = state
        .get_topology()
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    if let Some(existing_pane) = topology.panes.iter().find(|p| {
        topology
            .sessions
            .iter()
            .any(|s| s.name == session_name && s.id == p.session_id)
    }) {
        info!("reusing existing sessions-manager session");
        return Ok(Json(DashboardStartResponse {
            pane_id: existing_pane.id.clone(),
            session_name: session_name.to_string(),
        }));
    }

    // Create ~/.marmy/dashboard/ and write CLAUDE.md
    let home = dirs::home_dir().ok_or_else(|| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            "cannot determine home directory".to_string(),
        )
    })?;
    let dashboard_dir = home.join(".marmy").join("dashboard");
    std::fs::create_dir_all(&dashboard_dir).map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("failed to create dashboard directory: {}", e),
        )
    })?;

    let port = state.config.server.port;
    let claude_md = generate_claude_md(port);
    std::fs::write(dashboard_dir.join("CLAUDE.md"), &claude_md).map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("failed to write CLAUDE.md: {}", e),
        )
    })?;

    // Create tmux session in the dashboard directory
    let dir_str = dashboard_dir.to_string_lossy().to_string();
    state
        .tmux
        .new_session_in_dir(session_name, &dir_str)
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("failed to create tmux session: {}", e),
            )
        })?;

    // Set MARMY_TOKEN env var on the session
    state
        .tmux
        .set_session_env(session_name, "MARMY_TOKEN", &state.config.auth.token)
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("failed to set MARMY_TOKEN: {}", e),
            )
        })?;

    // Send the claude command
    state
        .tmux
        .send_text_enter(
            &format!("{}:0.0", session_name),
            "claude --dangerously-skip-permissions",
        )
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("failed to start claude: {}", e),
            )
        })?;

    // Refresh topology to pick up the new session
    let _ = state.refresh_topology().await;

    // Get the pane ID from the refreshed topology
    let topology = state
        .get_topology()
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    let pane_id = topology
        .panes
        .iter()
        .find(|p| {
            topology
                .sessions
                .iter()
                .any(|s| s.name == session_name && s.id == p.session_id)
        })
        .map(|p| p.id.clone())
        .unwrap_or_else(|| "%0".to_string());

    info!(pane_id = %pane_id, "started sessions-manager session");

    Ok(Json(DashboardStartResponse {
        pane_id,
        session_name: session_name.to_string(),
    }))
}

/// Generate the CLAUDE.md file content for the dashboard agent.
fn generate_claude_md(port: u16) -> String {
    format!(
        r#"# Sessions Manager

You are the sessions manager agent. Your job is to monitor all live Claude Code sessions running on this machine and report what they're doing.

## API Access

The marmy agent runs on `localhost:{port}`. Authenticate with `$MARMY_TOKEN`.

### List Live CC Sessions
```bash
curl -s -H "Authorization: Bearer $MARMY_TOKEN" http://localhost:{port}/api/cc/sessions | jq .
```
Returns every tmux pane currently running Claude Code:
- `session_name` — the tmux session name (e.g. "marmy", "guitarGrail")
- `pane_id` — tmux pane ID (e.g. "%9")
- `project_path` — working directory
- `current_command` — what's running (claude version string)

### Get Session Context (live output + conversation history)
```bash
curl -s -H "Authorization: Bearer $MARMY_TOKEN" http://localhost:{port}/api/cc/sessions/<PANE_ID>/context | jq .
```
Pass the pane ID **without** the `%` prefix (e.g. `9` not `%9`).
Returns:
- `pane_content` — current visible terminal output (what's on screen right now)
- `last_user_inputs` — last 5 things the user asked in this session
- `last_assistant_output` — the last thing Claude said

### Get Raw Pane Content
```bash
curl -s -H "Authorization: Bearer $MARMY_TOKEN" http://localhost:{port}/api/panes/<PANE_ID>/content | jq .
```
Same pane ID format (no `%` prefix). Returns raw terminal content.

### Send Input to a Session
```bash
curl -s -X POST -H "Authorization: Bearer $MARMY_TOKEN" -H "Content-Type: application/json" \
  -d '{{"keys": "your message here", "literal": true}}' \
  http://localhost:{port}/api/panes/<PANE_ID>/input
```
Sends text input to a pane. Use the pane ID **without** the `%` prefix.
- `keys` — the text to send
- `literal` — set to `true` to send text as-is (followed by Enter)

This lets you give instructions to other Claude sessions directly.

### Full Tmux Topology
```bash
curl -s -H "Authorization: Bearer $MARMY_TOKEN" http://localhost:{port}/api/sessions | jq .
```
Returns all tmux sessions, windows, and panes.

## Guidelines

1. **Always start** by calling the list sessions endpoint to see what's running
2. Summarize in a table: session name, project path, what it's working on
3. To see what a session is doing, get its context (pane content shows live output)
4. You can send instructions to any session using the input endpoint
5. Be concise — tables and bullet points
6. You are NOT one of these sessions — you are the manager observing them
"#,
        port = port
    )
}
