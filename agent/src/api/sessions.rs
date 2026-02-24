use axum::{extract::State, Json};

use crate::state::AppState;
use crate::tmux::TmuxTopology;

/// GET /api/sessions — full topology with sessions, windows, and panes.
pub async fn list_sessions(
    State(state): State<AppState>,
) -> Result<Json<TmuxTopology>, (axum::http::StatusCode, String)> {
    state
        .refresh_topology()
        .await
        .map_err(|e| (axum::http::StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    let topology = state
        .get_topology()
        .await
        .map_err(|e| (axum::http::StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    Ok(Json(topology))
}
