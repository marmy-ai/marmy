use std::path::PathBuf;

use axum::{extract::{Path, State}, http::StatusCode, Json};
use serde::{Deserialize, Serialize};
use tracing::info;

use crate::state::AppState;
use crate::tmux::types::EnrichedTopology;

/// Validate that a session name contains only safe characters (alphanumeric, underscore, hyphen)
/// and is between 1 and 64 characters. This prevents shell injection when session names are
/// interpolated into commands sent to tmux panes.
pub(crate) fn is_valid_session_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// Check if a working directory is within one of the configured allowed_paths.
/// Rejects paths outside the allowed set to prevent pane-cwd-based file browsing bypass.
fn is_working_dir_allowed(dir: &str, allowed_paths: &[String]) -> bool {
    // Resolve ~ in the requested dir
    let dir_path = if dir.starts_with('~') {
        if let Some(home) = dirs::home_dir() {
            home.join(dir[1..].trim_start_matches('/'))
        } else {
            PathBuf::from(dir)
        }
    } else {
        PathBuf::from(dir)
    };

    let canonical = match dir_path.canonicalize() {
        Ok(p) => p,
        Err(_) => return false,
    };

    for allowed in allowed_paths {
        let allowed_path = if allowed.starts_with('~') {
            if let Some(home) = dirs::home_dir() {
                home.join(allowed[1..].trim_start_matches('/'))
            } else {
                PathBuf::from(allowed)
            }
        } else {
            PathBuf::from(allowed)
        };

        if let Ok(allowed_canonical) = allowed_path.canonicalize() {
            if canonical.starts_with(&allowed_canonical) {
                return true;
            }
        }
    }

    false
}

#[derive(Deserialize)]
pub struct CreateSessionRequest {
    pub name: String,
    #[serde(default = "default_mode")]
    pub mode: String,
    pub working_dir: Option<String>,
    #[serde(default)]
    pub skip_permissions: bool,
}

fn default_mode() -> String {
    "terminal".to_string()
}

#[derive(Serialize)]
pub struct CreateSessionResponse {
    pub pane_id: String,
    pub session_name: String,
}

/// GET /api/sessions — full topology with sessions, windows, and panes (enriched with unread state).
pub async fn list_sessions(
    State(state): State<AppState>,
) -> Result<Json<EnrichedTopology>, (StatusCode, String)> {
    state
        .refresh_topology()
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    let topology = state
        .get_topology()
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    let unread = state.get_unread_sessions().await;
    let enriched = EnrichedTopology::from(&topology, &unread);

    info!(sessions = enriched.sessions.len(), windows = enriched.windows.len(), panes = enriched.panes.len(), "GET /api/sessions");

    Ok(Json(enriched))
}

/// POST /api/sessions — create a new tmux session.
pub async fn create_session(
    State(state): State<AppState>,
    Json(req): Json<CreateSessionRequest>,
) -> Result<(StatusCode, Json<CreateSessionResponse>), (StatusCode, String)> {
    let name = req.name.trim().to_string();
    if name.is_empty() {
        return Err((StatusCode::BAD_REQUEST, "session name is required".into()));
    }
    if !is_valid_session_name(&name) {
        return Err((
            StatusCode::BAD_REQUEST,
            "invalid session name: only alphanumeric characters, hyphens, and underscores are allowed (max 64 chars)".into(),
        ));
    }

    // Check for duplicate
    if let Ok(topo) = state.get_topology().await {
        if topo.sessions.iter().any(|s| s.name == name) {
            return Err((StatusCode::CONFLICT, format!("session '{}' already exists", name)));
        }
    }

    // Create session — with optional working directory
    if let Some(ref dir) = req.working_dir {
        if !state.config.files.allowed_paths.is_empty()
            && !is_working_dir_allowed(dir, &state.config.files.allowed_paths)
        {
            return Err((
                StatusCode::BAD_REQUEST,
                "working_dir is not within any configured allowed_paths".into(),
            ));
        }
        state
            .tmux
            .new_session_in_dir(&name, dir)
            .await
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    } else {
        state
            .tmux
            .new_session(&name)
            .await
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    }

    // If claude mode, launch Claude Code in the pane
    if req.mode == "claude" {
        let pane_target = format!("{}:0.0", name);
        let skip_flag = if req.skip_permissions {
            " --dangerously-skip-permissions"
        } else {
            ""
        };
        // Set token in tmux environment so it never appears in scrollback
        state
            .tmux
            .set_session_env(&name, "MARMY_TOKEN", &state.config.auth.token)
            .await
            .map_err(|e| {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    format!("failed to set env: {}", e),
                )
            })?;
        let launch_cmd = format!(
            "unset CLAUDECODE && eval $(tmux show-environment -t {} -s MARMY_TOKEN) && claude{}",
            name, skip_flag
        );
        state
            .tmux
            .send_text_enter(&pane_target, &launch_cmd)
            .await
            .map_err(|e| {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    format!("failed to start claude: {}", e),
                )
            })?;
    }

    // Refresh topology to pick up the new session
    let _ = state.refresh_topology().await;

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
                .any(|s| s.name == name && s.id == p.session_id)
        })
        .map(|p| p.id.clone())
        .unwrap_or_else(|| "%0".to_string());

    info!(pane_id = %pane_id, mode = %req.mode, "POST /api/sessions created '{}'", name);

    Ok((
        StatusCode::CREATED,
        Json(CreateSessionResponse {
            pane_id,
            session_name: name,
        }),
    ))
}

/// GET /api/sessions/recent-dirs — deduplicated working directories from all panes.
pub async fn recent_dirs(
    State(state): State<AppState>,
) -> Result<Json<Vec<String>>, (StatusCode, String)> {
    let _ = state.refresh_topology().await;
    let topology = state
        .get_topology()
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    let mut dirs: Vec<String> = topology
        .panes
        .iter()
        .map(|p| p.current_path.clone())
        .filter(|p| !p.is_empty())
        .collect();
    dirs.sort();
    dirs.dedup();

    info!(count = dirs.len(), "GET /api/sessions/recent-dirs");
    Ok(Json(dirs))
}

/// POST /api/sessions/:name/read — mark a session as read.
pub async fn mark_session_read(
    State(state): State<AppState>,
    Path(name): Path<String>,
) -> StatusCode {
    state.mark_session_read(&name).await;
    info!("marked session '{}' as read", name);
    StatusCode::OK
}

/// DELETE /api/sessions/:name — kill a tmux session.
pub async fn delete_session(
    State(state): State<AppState>,
    Path(name): Path<String>,
) -> Result<StatusCode, (StatusCode, String)> {
    if !is_valid_session_name(&name) {
        return Err((StatusCode::BAD_REQUEST, "invalid session name".into()));
    }
    state
        .tmux
        .kill_session(&name)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    // Clean up unread state for the deleted session
    state.mark_session_read(&name).await;

    Ok(StatusCode::NO_CONTENT)
}

#[cfg(test)]
mod tests {
    use super::*;

    // --- is_valid_session_name ---

    #[test]
    fn valid_simple_names() {
        assert!(is_valid_session_name("my-session"));
        assert!(is_valid_session_name("test_123"));
        assert!(is_valid_session_name("ProjectAlpha"));
    }

    #[test]
    fn valid_single_char() {
        assert!(is_valid_session_name("a"));
        assert!(is_valid_session_name("Z"));
        assert!(is_valid_session_name("0"));
        assert!(is_valid_session_name("_"));
        assert!(is_valid_session_name("-"));
    }

    #[test]
    fn valid_at_length_boundary() {
        let name_64 = "a".repeat(64);
        assert!(is_valid_session_name(&name_64));
    }

    #[test]
    fn rejects_empty() {
        assert!(!is_valid_session_name(""));
    }

    #[test]
    fn rejects_over_64_chars() {
        let name_65 = "a".repeat(65);
        assert!(!is_valid_session_name(&name_65));
    }

    #[test]
    fn rejects_shell_injection_semicolon() {
        assert!(!is_valid_session_name("x; rm -rf /"));
    }

    #[test]
    fn rejects_shell_injection_subshell() {
        assert!(!is_valid_session_name("$(whoami)"));
    }

    #[test]
    fn rejects_shell_injection_backtick() {
        assert!(!is_valid_session_name("`id`"));
    }

    #[test]
    fn rejects_dots_and_special_chars() {
        // Dots are valid in tmux session names but we reject them
        // to keep the shell interpolation safe.
        assert!(!is_valid_session_name("my.session"));
        assert!(!is_valid_session_name("has spaces"));
        assert!(!is_valid_session_name("has/slash"));
        assert!(!is_valid_session_name("pipe|here"));
        assert!(!is_valid_session_name("amp&ersand"));
        assert!(!is_valid_session_name("quote'mark"));
        assert!(!is_valid_session_name("double\"quote"));
    }

    #[test]
    fn rejects_newlines_and_control_chars() {
        assert!(!is_valid_session_name("line\nbreak"));
        assert!(!is_valid_session_name("tab\there"));
        assert!(!is_valid_session_name("null\0byte"));
    }

    // --- is_working_dir_allowed ---

    #[test]
    fn working_dir_allowed_inside_allowed_path() {
        let parent = tempfile::tempdir().unwrap();
        let child = parent.path().join("project");
        std::fs::create_dir(&child).unwrap();

        let allowed = vec![parent.path().to_string_lossy().to_string()];
        assert!(is_working_dir_allowed(&child.to_string_lossy(), &allowed));
    }

    #[test]
    fn working_dir_rejected_outside_allowed_path() {
        let allowed_dir = tempfile::tempdir().unwrap();
        let other_dir = tempfile::tempdir().unwrap();

        let allowed = vec![allowed_dir.path().to_string_lossy().to_string()];
        assert!(!is_working_dir_allowed(&other_dir.path().to_string_lossy(), &allowed));
    }

    #[test]
    fn working_dir_rejected_nonexistent_path() {
        let allowed = vec!["/tmp".to_string()];
        assert!(!is_working_dir_allowed("/nonexistent/fake/path/xyz", &allowed));
    }

    #[test]
    fn working_dir_exact_match_is_allowed() {
        let dir = tempfile::tempdir().unwrap();
        let allowed = vec![dir.path().to_string_lossy().to_string()];
        assert!(is_working_dir_allowed(&dir.path().to_string_lossy(), &allowed));
    }

    #[test]
    fn working_dir_parent_traversal_rejected() {
        // allowed is /tmp/parent/child, request is /tmp/parent — should fail
        let parent = tempfile::tempdir().unwrap();
        let child = parent.path().join("child");
        std::fs::create_dir(&child).unwrap();

        let allowed = vec![child.to_string_lossy().to_string()];
        assert!(!is_working_dir_allowed(&parent.path().to_string_lossy(), &allowed));
    }

    #[test]
    fn working_dir_multiple_allowed_paths() {
        let dir_a = tempfile::tempdir().unwrap();
        let dir_b = tempfile::tempdir().unwrap();
        let dir_c = tempfile::tempdir().unwrap();

        let allowed = vec![
            dir_a.path().to_string_lossy().to_string(),
            dir_b.path().to_string_lossy().to_string(),
        ];

        // dir_b is in allowed list
        assert!(is_working_dir_allowed(&dir_b.path().to_string_lossy(), &allowed));
        // dir_c is not
        assert!(!is_working_dir_allowed(&dir_c.path().to_string_lossy(), &allowed));
    }
}
