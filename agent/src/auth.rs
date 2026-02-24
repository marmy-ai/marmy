use axum::{
    extract::Request,
    http::StatusCode,
    middleware::Next,
    response::Response,
};

/// Axum middleware that validates Bearer token authentication.
pub async fn auth_middleware(request: Request, next: Next) -> Result<Response, StatusCode> {
    let token = request
        .headers()
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "));

    let expected = request
        .extensions()
        .get::<AuthToken>()
        .map(|t| t.0.as_str());

    match (token, expected) {
        (Some(token), Some(expected)) if token == expected => Ok(next.run(request).await),
        (None, _) => Err(StatusCode::UNAUTHORIZED),
        _ => Err(StatusCode::FORBIDDEN),
    }
}

/// Extension type carrying the expected auth token.
#[derive(Clone)]
pub struct AuthToken(pub String);
