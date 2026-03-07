use std::path::{Path, PathBuf};

use axum::{
    extract::{Query, State},
    http::{header, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use serde::{Deserialize, Serialize};

use crate::state::AppState;

#[derive(Deserialize)]
pub struct PathQuery {
    pub path: String,
}

#[derive(Deserialize)]
pub struct SessionRootsQuery {
    pub session_id: String,
}

#[derive(Serialize)]
pub struct DirEntry {
    pub name: String,
    pub path: String,
    pub is_dir: bool,
    pub size: u64,
}

#[derive(Serialize)]
pub struct DirListing {
    pub path: String,
    pub entries: Vec<DirEntry>,
}

#[derive(Serialize)]
pub struct FileContent {
    pub path: String,
    pub content: String,
    pub size: u64,
}

#[derive(Serialize)]
pub struct SessionRoot {
    pub path: String,
    pub pane_id: String,
    pub window_name: String,
    pub current_command: String,
}

/// GET /api/files/roots — return configured allowed_paths.
pub async fn list_roots(
    State(state): State<AppState>,
) -> Json<Vec<String>> {
    let roots: Vec<String> = state
        .config
        .files
        .allowed_paths
        .iter()
        .map(|p| resolve_path(p).to_string_lossy().to_string())
        .collect();
    Json(roots)
}

/// GET /api/files/session-roots?session_id=... — return working directories for a session's panes.
pub async fn session_roots(
    State(state): State<AppState>,
    Query(query): Query<SessionRootsQuery>,
) -> Result<Json<Vec<SessionRoot>>, (StatusCode, String)> {
    let topology = state
        .get_topology()
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    // Find windows belonging to this session
    let session_window_ids: Vec<&str> = topology
        .windows
        .iter()
        .filter(|w| w.session_id == query.session_id)
        .map(|w| w.id.as_str())
        .collect();

    // Build a window_id -> window_name lookup
    let window_name = |wid: &str| -> String {
        topology
            .windows
            .iter()
            .find(|w| w.id == wid)
            .map(|w| w.name.clone())
            .unwrap_or_default()
    };

    // Collect pane roots, deduplicated by path (keep first occurrence)
    let mut seen = std::collections::HashSet::new();
    let mut roots = Vec::new();

    for pane in &topology.panes {
        if session_window_ids.contains(&pane.window_id.as_str()) {
            if seen.insert(pane.current_path.clone()) {
                roots.push(SessionRoot {
                    path: pane.current_path.clone(),
                    pane_id: pane.id.clone(),
                    window_name: window_name(&pane.window_id),
                    current_command: pane.current_command.clone(),
                });
            }
        }
    }

    Ok(Json(roots))
}

/// GET /api/files/tree?path=... — list directory contents.
pub async fn list_dir(
    State(state): State<AppState>,
    Query(query): Query<PathQuery>,
) -> Result<Json<DirListing>, (StatusCode, String)> {
    let path = resolve_path(&query.path);

    if !is_path_allowed_for_browsing(&path, &state).await {
        return Err((StatusCode::FORBIDDEN, "path not in allowed directories".to_string()));
    }

    let mut entries = Vec::new();
    let read_dir = tokio::fs::read_dir(&path)
        .await
        .map_err(|e| (StatusCode::NOT_FOUND, e.to_string()))?;

    let mut read_dir = read_dir;
    while let Ok(Some(entry)) = read_dir.next_entry().await {
        let name = entry.file_name().to_string_lossy().to_string();

        // Skip hidden files starting with '.'
        if name.starts_with('.') {
            continue;
        }

        let metadata = entry.metadata().await.unwrap_or_else(|_| {
            // Fallback: treat as empty file
            std::fs::metadata(entry.path()).unwrap_or_else(|_| {
                std::fs::metadata("/dev/null").unwrap()
            })
        });

        entries.push(DirEntry {
            name,
            path: entry.path().to_string_lossy().to_string(),
            is_dir: metadata.is_dir(),
            size: metadata.len(),
        });
    }

    // Sort: directories first, then alphabetically
    entries.sort_by(|a, b| {
        b.is_dir.cmp(&a.is_dir).then(a.name.cmp(&b.name))
    });

    Ok(Json(DirListing {
        path: path.to_string_lossy().to_string(),
        entries,
    }))
}

/// GET /api/files/content?path=... — read file contents.
pub async fn read_file(
    State(state): State<AppState>,
    Query(query): Query<PathQuery>,
) -> Result<Json<FileContent>, (StatusCode, String)> {
    let path = resolve_path(&query.path);

    if has_hidden_component(&path) {
        return Err((StatusCode::FORBIDDEN, "access to hidden files is not allowed".to_string()));
    }

    if !is_path_allowed_dynamic(&path, &state).await {
        return Err((StatusCode::FORBIDDEN, "path not in allowed directories".to_string()));
    }

    let metadata = tokio::fs::metadata(&path)
        .await
        .map_err(|e| (StatusCode::NOT_FOUND, e.to_string()))?;

    // Refuse to read files larger than 2MB
    if metadata.len() > 2 * 1024 * 1024 {
        return Err((StatusCode::BAD_REQUEST, "file too large (>2MB)".to_string()));
    }

    let content = tokio::fs::read_to_string(&path)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    Ok(Json(FileContent {
        path: path.to_string_lossy().to_string(),
        content,
        size: metadata.len(),
    }))
}

/// GET /api/files/raw?path=... — serve raw file bytes with correct Content-Type.
pub async fn raw_file(
    State(state): State<AppState>,
    Query(query): Query<PathQuery>,
) -> Result<Response, (StatusCode, String)> {
    let path = resolve_path(&query.path);

    if has_hidden_component(&path) {
        return Err((StatusCode::FORBIDDEN, "access to hidden files is not allowed".to_string()));
    }

    if !is_path_allowed_dynamic(&path, &state).await {
        return Err((StatusCode::FORBIDDEN, "path not in allowed directories".to_string()));
    }

    let metadata = tokio::fs::metadata(&path)
        .await
        .map_err(|e| (StatusCode::NOT_FOUND, e.to_string()))?;

    // 10MB limit for binary files
    if metadata.len() > 10 * 1024 * 1024 {
        return Err((StatusCode::BAD_REQUEST, "file too large (>10MB)".to_string()));
    }

    let bytes = tokio::fs::read(&path)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    let content_type = guess_content_type(&path);

    Ok((
        [(header::CONTENT_TYPE, content_type)],
        bytes,
    ).into_response())
}

/// Check if any component of the path starts with '.' (hidden file/directory).
fn has_hidden_component(path: &Path) -> bool {
    path.components().any(|c| {
        c.as_os_str()
            .to_str()
            .map_or(false, |s| s.starts_with('.'))
    })
}

/// Resolve ~ and relative paths to absolute.
fn resolve_path(path: &str) -> PathBuf {
    if path.starts_with('~') {
        if let Some(home) = dirs::home_dir() {
            return home.join(&path[1..].trim_start_matches('/'));
        }
    }
    PathBuf::from(path)
}

/// Check if a path is within one of the allowed directories.
fn is_path_allowed(path: &Path, allowed: &[String]) -> bool {
    if allowed.is_empty() {
        return false;
    }

    let path = match path.canonicalize() {
        Ok(p) => p,
        Err(_) => return false,
    };

    for allowed_path in allowed {
        let allowed = resolve_path(allowed_path);
        if let Ok(allowed) = allowed.canonicalize() {
            if path.starts_with(&allowed) {
                return true;
            }
        }
    }

    false
}

/// Dynamic path validation: checks static allowed_paths first, then pane working directories.
async fn is_path_allowed_dynamic(path: &Path, state: &AppState) -> bool {
    // Static config check first
    if is_path_allowed(path, &state.config.files.allowed_paths) {
        return true;
    }

    // Dynamic check: is this path under any pane's current_path?
    let topology = match state.get_topology().await {
        Ok(t) => t,
        Err(_) => return false,
    };

    let canonical = match path.canonicalize() {
        Ok(p) => p,
        Err(_) => return false,
    };

    for pane in &topology.panes {
        let pane_path = PathBuf::from(&pane.current_path);
        if let Ok(pane_canonical) = pane_path.canonicalize() {
            // Skip panes at filesystem root — too broad
            if pane_canonical == PathBuf::from("/") {
                continue;
            }
            if canonical.starts_with(&pane_canonical) {
                return true;
            }
        }
    }

    false
}

/// Like is_path_allowed_dynamic, but also allows ancestor directories of pane paths.
/// Used for directory browsing (list_dir) so users can navigate down to pane working dirs.
async fn is_path_allowed_for_browsing(path: &Path, state: &AppState) -> bool {
    if is_path_allowed_dynamic(path, state).await {
        return true;
    }

    // Allow ancestors of pane working directories (for navigating down)
    let topology = match state.get_topology().await {
        Ok(t) => t,
        Err(_) => return false,
    };

    let canonical = match path.canonicalize() {
        Ok(p) => p,
        Err(_) => return false,
    };

    for pane in &topology.panes {
        let pane_path = PathBuf::from(&pane.current_path);
        if let Ok(pane_canonical) = pane_path.canonicalize() {
            if pane_canonical.starts_with(&canonical) {
                return true;
            }
        }
    }

    // Also allow ancestors of static allowed_paths
    for allowed_path in &state.config.files.allowed_paths {
        let allowed = resolve_path(allowed_path);
        if let Ok(allowed_canonical) = allowed.canonicalize() {
            if allowed_canonical.starts_with(&canonical) {
                return true;
            }
        }
    }

    false
}

/// Map file extension to MIME type for raw serving.
fn guess_content_type(path: &Path) -> &'static str {
    match path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase())
        .as_deref()
    {
        Some("png") => "image/png",
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("gif") => "image/gif",
        Some("webp") => "image/webp",
        Some("svg") => "image/svg+xml",
        Some("bmp") => "image/bmp",
        Some("ico") => "image/x-icon",
        Some("pdf") => "application/pdf",
        Some("json") => "application/json",
        Some("js" | "mjs") => "text/javascript",
        Some("css") => "text/css",
        Some("html" | "htm") => "text/html",
        Some("txt" | "md" | "rs" | "toml" | "yaml" | "yml") => "text/plain",
        _ => "application/octet-stream",
    }
}
