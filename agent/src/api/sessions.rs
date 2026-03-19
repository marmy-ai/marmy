use axum::{extract::{Path, State}, http::StatusCode, Json};
use serde::{Deserialize, Serialize};
use tracing::info;

use crate::state::AppState;
use crate::tmux::types::EnrichedTopology;

/// Validate that a session name contains only safe characters (alphanumeric, underscore, hyphen)
/// and is between 1 and 64 characters. This prevents shell injection when session names are
/// interpolated into commands sent to tmux panes.
fn is_valid_session_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
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
