use axum::{extract::State, http::StatusCode, Json};
use serde::Serialize;

use crate::state::AppState;

#[derive(Serialize)]
pub struct VoiceTokenResponse {
    pub token: String,
}

/// GET /api/voice/token
pub async fn get_voice_token(
    State(state): State<AppState>,
) -> Result<Json<VoiceTokenResponse>, (StatusCode, String)> {
    let key = &state.config.voice.gemini_api_key;
    if key.is_empty() {
        return Err((
            StatusCode::SERVICE_UNAVAILABLE,
            "gemini_api_key not configured".into(),
        ));
    }
    Ok(Json(VoiceTokenResponse {
        token: key.clone(),
    }))
}
