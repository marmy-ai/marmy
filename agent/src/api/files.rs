use std::path::{Path, PathBuf};

use axum::{
    extract::{Query, State},
    http::StatusCode,
    Json,
};
use serde::{Deserialize, Serialize};

use crate::state::AppState;

#[derive(Deserialize)]
pub struct PathQuery {
    pub path: String,
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

/// GET /api/files/tree?path=... — list directory contents.
pub async fn list_dir(
    State(state): State<AppState>,
    Query(query): Query<PathQuery>,
) -> Result<Json<DirListing>, (StatusCode, String)> {
    let path = resolve_path(&query.path);

    if !is_path_allowed(&path, &state.config.files.allowed_paths) {
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

    if !is_path_allowed(&path, &state.config.files.allowed_paths) {
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
