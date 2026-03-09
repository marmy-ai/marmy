pub mod cc;
pub mod files;
pub mod notifications;
pub mod panes;
pub mod sessions;
pub mod voice;
pub mod ws;

use axum::{
    http::{header, Method},
    middleware,
    routing::{delete, get, post},
    Extension, Router,
};
use tower_http::cors::{Any, CorsLayer};
use crate::auth::{auth_middleware, AuthToken};
use crate::state::AppState;

pub fn build_router(state: AppState) -> Router {
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods([Method::GET, Method::POST, Method::DELETE])
        .allow_headers([header::AUTHORIZATION, header::CONTENT_TYPE]);

    // Public route: WebSocket (auth via query param)
    let ws_routes = Router::new().route("/ws", get(ws::ws_handler));

    // Authenticated API routes
    let api_routes = Router::new()
        .route("/api/sessions", get(sessions::list_sessions).post(sessions::create_session))
        .route("/api/sessions/recent-dirs", get(sessions::recent_dirs))
        .route("/api/sessions/:name", delete(sessions::delete_session))
        .route("/api/panes/:id/input", post(panes::send_input))
        .route("/api/panes/:id/resize", post(panes::resize_pane))
        .route("/api/panes/:id/content", get(panes::get_content))
        .route("/api/panes/:id/history", get(panes::get_history))
        .route("/api/files/roots", get(files::list_roots))
        .route("/api/files/session-roots", get(files::session_roots))
        .route("/api/files/tree", get(files::list_dir))
        .route("/api/files/content", get(files::read_file))
        .route("/api/files/raw", get(files::raw_file))
        .route("/api/cc/sessions", get(cc::list_sessions))
        .route("/api/cc/sessions/:id/context", get(cc::get_session_context))
        .route("/api/cc/dashboard/start", post(cc::start_dashboard))
        .route("/api/notifications/register", post(notifications::register_token).delete(notifications::unregister_token))
        .route("/api/notifications/send", post(notifications::send_notification))
        .route("/api/notifications/hook", post(notifications::set_hook))
        .route("/api/notifications/test", post(notifications::test_notification))
        .route("/api/notifications/debug", get(notifications::debug_notifications))
        .route("/api/voice/token", get(voice::get_voice_token))
        .layer(middleware::from_fn(auth_middleware))
        .layer(Extension(AuthToken(state.config.auth.token.clone())));

    Router::new()
        .merge(ws_routes)
        .merge(api_routes)
        .layer(cors)
        .with_state(state)
}
