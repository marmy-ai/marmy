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

/// Check if a pane's cwd is itself under one of the configured allowed_paths.
/// Returns false if allowed_paths is empty (file browsing disabled).
fn is_pane_cwd_within_allowed(pane_canonical: &std::path::Path, allowed_paths: &[String]) -> bool {
    for allowed_path in allowed_paths {
        let allowed = resolve_path(allowed_path);
        if let Ok(allowed_canonical) = allowed.canonicalize() {
            if pane_canonical.starts_with(&allowed_canonical) {
                return true;
            }
        }
    }
    false
}

/// Dynamic path validation: checks static allowed_paths first, then pane working directories.
/// When allowed_paths is configured, pane cwds only count if they are themselves under an
/// allowed_path. When allowed_paths is empty (default), any pane cwd is allowed — this is
/// the sane default for a single-user tool.
async fn is_path_allowed_dynamic(path: &Path, state: &AppState) -> bool {
    let allowed_paths = &state.config.files.allowed_paths;

    // Static config check first
    if is_path_allowed(path, allowed_paths) {
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
            if pane_canonical == PathBuf::from("/") {
                continue;
            }
            // If allowed_paths is configured, pane cwds must be under an allowed path.
            // If allowed_paths is empty (default), any pane cwd is permitted.
            if canonical.starts_with(&pane_canonical)
                && (allowed_paths.is_empty()
                    || is_pane_cwd_within_allowed(&pane_canonical, allowed_paths))
            {
                return true;
            }
        }
    }

    false
}

/// Like is_path_allowed_dynamic, but also allows ancestor directories of allowed pane paths.
/// Used for directory browsing (list_dir) so users can navigate down to pane working dirs.
async fn is_path_allowed_for_browsing(path: &Path, state: &AppState) -> bool {
    if is_path_allowed_dynamic(path, state).await {
        return true;
    }

    let canonical = match path.canonicalize() {
        Ok(p) => p,
        Err(_) => return false,
    };

    let allowed_paths = &state.config.files.allowed_paths;

    // Allow ancestors of pane working directories so users can navigate down
    let topology = match state.get_topology().await {
        Ok(t) => t,
        Err(_) => return false,
    };

    for pane in &topology.panes {
        let pane_path = PathBuf::from(&pane.current_path);
        if let Ok(pane_canonical) = pane_path.canonicalize() {
            if pane_canonical.starts_with(&canonical)
                && (allowed_paths.is_empty()
                    || is_pane_cwd_within_allowed(&pane_canonical, allowed_paths))
            {
                return true;
            }
        }
    }

    // Also allow ancestors of static allowed_paths
    for allowed_path in allowed_paths {
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

#[cfg(test)]
mod tests {
    use super::*;

    // --- resolve_path ---

    #[test]
    fn resolve_path_tilde_expands_to_home() {
        let result = resolve_path("~/projects");
        let home = dirs::home_dir().unwrap();
        assert_eq!(result, home.join("projects"));
    }

    #[test]
    fn resolve_path_tilde_alone() {
        let result = resolve_path("~");
        let home = dirs::home_dir().unwrap();
        assert_eq!(result, home);
    }

    #[test]
    fn resolve_path_absolute_unchanged() {
        let result = resolve_path("/usr/local/bin");
        assert_eq!(result, PathBuf::from("/usr/local/bin"));
    }

    #[test]
    fn resolve_path_relative_unchanged() {
        let result = resolve_path("relative/path");
        assert_eq!(result, PathBuf::from("relative/path"));
    }

    // --- has_hidden_component ---

    #[test]
    fn hidden_component_dotfile_at_leaf() {
        assert!(has_hidden_component(Path::new("/home/user/.bashrc")));
    }

    #[test]
    fn hidden_component_dotdir_in_middle() {
        assert!(has_hidden_component(Path::new("/home/user/.config/app/settings")));
    }

    #[test]
    fn hidden_component_none() {
        assert!(!has_hidden_component(Path::new("/home/user/projects/readme.md")));
    }

    #[test]
    fn hidden_component_dot_in_filename_not_at_start() {
        // "file.txt" has a dot but the component doesn't start with it
        assert!(!has_hidden_component(Path::new("/home/user/file.txt")));
    }

    #[test]
    fn hidden_component_at_root() {
        assert!(has_hidden_component(Path::new("/.hidden/file")));
    }

    // --- guess_content_type ---

    #[test]
    fn content_type_images() {
        assert_eq!(guess_content_type(Path::new("photo.png")), "image/png");
        assert_eq!(guess_content_type(Path::new("photo.jpg")), "image/jpeg");
        assert_eq!(guess_content_type(Path::new("photo.jpeg")), "image/jpeg");
        assert_eq!(guess_content_type(Path::new("anim.gif")), "image/gif");
        assert_eq!(guess_content_type(Path::new("photo.webp")), "image/webp");
        assert_eq!(guess_content_type(Path::new("icon.svg")), "image/svg+xml");
        assert_eq!(guess_content_type(Path::new("icon.bmp")), "image/bmp");
        assert_eq!(guess_content_type(Path::new("icon.ico")), "image/x-icon");
    }

    #[test]
    fn content_type_code_and_text() {
        assert_eq!(guess_content_type(Path::new("app.js")), "text/javascript");
        assert_eq!(guess_content_type(Path::new("lib.mjs")), "text/javascript");
        assert_eq!(guess_content_type(Path::new("style.css")), "text/css");
        assert_eq!(guess_content_type(Path::new("page.html")), "text/html");
        assert_eq!(guess_content_type(Path::new("old.htm")), "text/html");
        assert_eq!(guess_content_type(Path::new("README.md")), "text/plain");
        assert_eq!(guess_content_type(Path::new("main.rs")), "text/plain");
        assert_eq!(guess_content_type(Path::new("config.toml")), "text/plain");
        assert_eq!(guess_content_type(Path::new("data.yaml")), "text/plain");
        assert_eq!(guess_content_type(Path::new("data.yml")), "text/plain");
        assert_eq!(guess_content_type(Path::new("notes.txt")), "text/plain");
    }

    #[test]
    fn content_type_structured() {
        assert_eq!(guess_content_type(Path::new("data.json")), "application/json");
        assert_eq!(guess_content_type(Path::new("doc.pdf")), "application/pdf");
    }

    #[test]
    fn content_type_unknown_extension() {
        assert_eq!(guess_content_type(Path::new("file.xyz")), "application/octet-stream");
    }

    #[test]
    fn content_type_no_extension() {
        assert_eq!(guess_content_type(Path::new("Makefile")), "application/octet-stream");
    }

    #[test]
    fn content_type_case_insensitive() {
        assert_eq!(guess_content_type(Path::new("PHOTO.PNG")), "image/png");
        assert_eq!(guess_content_type(Path::new("data.JSON")), "application/json");
        assert_eq!(guess_content_type(Path::new("page.Html")), "text/html");
    }

    // --- is_path_allowed ---

    #[test]
    fn path_allowed_empty_list_rejects_everything() {
        let allowed: Vec<String> = vec![];
        assert!(!is_path_allowed(Path::new("/tmp"), &allowed));
    }

    #[test]
    fn path_allowed_nonexistent_path_rejected() {
        // canonicalize will fail on a path that doesn't exist
        let allowed = vec!["/tmp".to_string()];
        assert!(!is_path_allowed(Path::new("/nonexistent/fake/path"), &allowed));
    }

    #[test]
    fn path_allowed_within_allowed_dir() {
        // Use /tmp itself — canonicalizes to /private/tmp on macOS
        let allowed = vec!["/tmp".to_string()];
        assert!(is_path_allowed(Path::new("/tmp"), &allowed));
    }

    #[test]
    fn path_allowed_outside_allowed_dir() {
        let allowed = vec!["/tmp".to_string()];
        // /usr is not under /tmp
        assert!(!is_path_allowed(Path::new("/usr"), &allowed));
    }

    // --- is_path_allowed with tempfile ---

    #[test]
    fn path_allowed_subdir_of_allowed() {
        let parent = tempfile::tempdir().unwrap();
        let child = parent.path().join("sub");
        std::fs::create_dir(&child).unwrap();

        let allowed = vec![parent.path().to_string_lossy().to_string()];
        assert!(is_path_allowed(&child, &allowed));
    }

    #[test]
    fn path_allowed_parent_of_allowed_rejected() {
        let parent = tempfile::tempdir().unwrap();
        let child = parent.path().join("sub");
        std::fs::create_dir(&child).unwrap();

        let allowed = vec![child.to_string_lossy().to_string()];
        assert!(!is_path_allowed(parent.path(), &allowed));
    }

    #[test]
    fn path_allowed_symlink_resolved() {
        // Create dir and a symlink to it — both should resolve to same canonical path
        let real_dir = tempfile::tempdir().unwrap();
        let link_parent = tempfile::tempdir().unwrap();
        let link_path = link_parent.path().join("link");
        std::os::unix::fs::symlink(real_dir.path(), &link_path).unwrap();

        let allowed = vec![real_dir.path().to_string_lossy().to_string()];
        assert!(is_path_allowed(&link_path, &allowed));
    }

    #[test]
    fn path_allowed_multiple_allowed_paths() {
        let dir_a = tempfile::tempdir().unwrap();
        let dir_b = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();

        let allowed = vec![
            dir_a.path().to_string_lossy().to_string(),
            dir_b.path().to_string_lossy().to_string(),
        ];
        assert!(is_path_allowed(dir_a.path(), &allowed));
        assert!(is_path_allowed(dir_b.path(), &allowed));
        assert!(!is_path_allowed(outside.path(), &allowed));
    }

    // --- is_pane_cwd_within_allowed ---

    #[test]
    fn pane_cwd_within_allowed_path() {
        let parent = tempfile::tempdir().unwrap();
        let pane_dir = parent.path().join("project");
        std::fs::create_dir(&pane_dir).unwrap();

        let allowed = vec![parent.path().to_string_lossy().to_string()];
        let pane_canonical = pane_dir.canonicalize().unwrap();
        assert!(is_pane_cwd_within_allowed(&pane_canonical, &allowed));
    }

    #[test]
    fn pane_cwd_outside_allowed_path() {
        let allowed_dir = tempfile::tempdir().unwrap();
        let pane_dir = tempfile::tempdir().unwrap();

        let allowed = vec![allowed_dir.path().to_string_lossy().to_string()];
        let pane_canonical = pane_dir.path().canonicalize().unwrap();
        assert!(!is_pane_cwd_within_allowed(&pane_canonical, &allowed));
    }

    #[test]
    fn pane_cwd_empty_allowed_paths_rejects() {
        let pane_dir = tempfile::tempdir().unwrap();
        let pane_canonical = pane_dir.path().canonicalize().unwrap();
        assert!(!is_pane_cwd_within_allowed(&pane_canonical, &[]));
    }

    #[test]
    fn pane_cwd_exact_match_allowed() {
        let dir = tempfile::tempdir().unwrap();
        let allowed = vec![dir.path().to_string_lossy().to_string()];
        let canonical = dir.path().canonicalize().unwrap();
        assert!(is_pane_cwd_within_allowed(&canonical, &allowed));
    }

    // --- empty allowed_paths default behavior ---
    // When allowed_paths is empty (the default), is_path_allowed_dynamic allows
    // any pane cwd. We can't call the async function here, but we verify the
    // building blocks behave correctly for the empty case:

    #[test]
    fn static_path_check_rejects_when_allowed_empty() {
        // is_path_allowed returns false for empty list — this is correct because
        // the dynamic pane-cwd path handles the empty default case.
        assert!(!is_path_allowed(Path::new("/tmp"), &[]));
    }

    #[test]
    fn pane_cwd_check_rejects_when_allowed_empty() {
        // is_pane_cwd_within_allowed returns false for empty list — this is correct
        // because is_path_allowed_dynamic skips this check when allowed_paths is empty,
        // allowing any pane cwd by default.
        let dir = tempfile::tempdir().unwrap();
        let canonical = dir.path().canonicalize().unwrap();
        assert!(!is_pane_cwd_within_allowed(&canonical, &[]));
    }
}
