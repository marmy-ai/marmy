pub mod files;
pub mod panes;
pub mod sessions;
pub mod ws;

use axum::{
    routing::{get, post},
    Router,
};
use tower_http::cors::{Any, CorsLayer};
use crate::state::AppState;

pub fn build_router(state: AppState) -> Router {
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    // Public route: WebSocket (auth via query param or first message)
    let ws_routes = Router::new().route("/ws", get(ws::ws_handler));

    // Authenticated API routes
    let api_routes = Router::new()
        .route("/api/sessions", get(sessions::list_sessions))
        .route("/api/panes/:id/input", post(panes::send_input))
        .route("/api/panes/:id/resize", post(panes::resize_pane))
        .route("/api/panes/:id/content", get(panes::get_content))
        .route("/api/panes/:id/history", get(panes::get_history))
        .route("/api/files/tree", get(files::list_dir))
        .route("/api/files/content", get(files::read_file));

    Router::new()
        .merge(ws_routes)
        .merge(api_routes)
        .layer(cors)
        .with_state(state)
}
