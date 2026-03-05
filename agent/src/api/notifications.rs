use axum::{
    extract::State,
    http::StatusCode,
    Json,
};
use serde::Deserialize;
use tracing::info;

use crate::state::AppState;

#[derive(Deserialize)]
pub struct TokenRequest {
    pub token: String,
}

/// POST /api/notifications/register
pub async fn register_token(
    State(state): State<AppState>,
    Json(body): Json<TokenRequest>,
) -> StatusCode {
    info!("registering push token: {}...", &body.token[..body.token.len().min(20)]);
    state.register_push_token(body.token).await;
    StatusCode::OK
}

/// DELETE /api/notifications/register
pub async fn unregister_token(
    State(state): State<AppState>,
    Json(body): Json<TokenRequest>,
) -> StatusCode {
    info!("unregistering push token");
    state.unregister_push_token(&body.token).await;
    StatusCode::OK
}

/// GET /api/notifications/debug
pub async fn debug_notifications(
    State(state): State<AppState>,
) -> Json<serde_json::Value> {
    let detector = state.detector.lock().await;
    let tokens = state.get_push_tokens().await;
    let mut debug = detector.debug_state();
    debug.as_object_mut().unwrap().insert(
        "registered_tokens".to_string(),
        serde_json::json!(tokens.len()),
    );
    Json(debug)
}

/// POST /api/notifications/test
pub async fn test_notification(
    State(state): State<AppState>,
) -> Result<StatusCode, (StatusCode, String)> {
    let tokens = state.get_push_tokens().await;
    if tokens.is_empty() {
        return Err((StatusCode::BAD_REQUEST, "no push tokens registered".to_string()));
    }

    let detector = state.detector.lock().await;
    detector.send_test(&tokens).await;

    info!("sent test notification to {} token(s)", tokens.len());
    Ok(StatusCode::OK)
}
