use axum::{extract::{Path, State}, http::StatusCode, Json};
use serde::Deserialize;

use crate::state::AppState;
use crate::tmux::TmuxTopology;

#[derive(Deserialize)]
pub struct CreateSessionRequest {
    pub name: String,
}

/// GET /api/sessions — full topology with sessions, windows, and panes.
pub async fn list_sessions(
    State(state): State<AppState>,
) -> Result<Json<TmuxTopology>, (StatusCode, String)> {
    state
        .refresh_topology()
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    let topology = state
        .get_topology()
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    Ok(Json(topology))
}

/// POST /api/sessions — create a new tmux session.
pub async fn create_session(
    State(state): State<AppState>,
    Json(req): Json<CreateSessionRequest>,
) -> Result<StatusCode, (StatusCode, String)> {
    let name = req.name.trim().to_string();
    if name.is_empty() {
        return Err((StatusCode::BAD_REQUEST, "session name is required".into()));
    }

    // Check for duplicate
    if let Ok(topo) = state.get_topology().await {
        if topo.sessions.iter().any(|s| s.name == name) {
            return Err((StatusCode::CONFLICT, format!("session '{}' already exists", name)));
        }
    }

    state
        .tmux
        .new_session(&name)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    Ok(StatusCode::CREATED)
}

/// DELETE /api/sessions/:name — kill a tmux session.
pub async fn delete_session(
    State(state): State<AppState>,
    Path(name): Path<String>,
) -> Result<StatusCode, (StatusCode, String)> {
    state
        .tmux
        .kill_session(&name)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    Ok(StatusCode::NO_CONTENT)
}
