use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use sha2::{Digest, Sha256};
use tracing::{error, info, warn};

use crate::config::NotificationsConfig;
use crate::state::AppState;

/// Per-pane state: tracks whether content was changing (active) or stable (idle).
/// We only notify on the transition from active → idle.
struct PaneState {
    prev_hash: String,
    /// true = content has been changing recently (Claude is working)
    was_active: bool,
    /// true = we already sent a notification for the current idle period
    notified: bool,
}

pub struct NotificationDetector {
    panes: HashMap<String, PaneState>,
    apns: ApnsClient,
    /// Suppress all notifications for the first N cycles to establish baseline.
    warmup_remaining: u32,
}

impl NotificationDetector {
    pub fn new(config: &NotificationsConfig) -> Self {
        Self {
            panes: HashMap::new(),
            apns: ApnsClient::new(config),
            warmup_remaining: 5, // ~10s at 2s poll
        }
    }

    pub async fn check_and_notify(&mut self, state: &AppState) {
        if !state.config.notifications.enabled || !self.apns.is_configured() {
            return;
        }

        let tokens = state.get_push_tokens().await;
        if tokens.is_empty() {
            return;
        }

        let in_warmup = self.warmup_remaining > 0;
        self.warmup_remaining = self.warmup_remaining.saturating_sub(1);

        let topology = match state.get_topology().await {
            Ok(t) => t,
            Err(_) => return,
        };

        for pane in &topology.panes {
            let session_name = topology
                .sessions
                .iter()
                .find(|s| s.id == pane.session_id)
                .map(|s| s.name.clone())
                .unwrap_or_default();

            if session_name == "_marmy_ctrl" || session_name == "sessions-manager" {
                continue;
            }

            if !is_claude_process(&pane.current_command) {
                self.panes.remove(&pane.id);
                continue;
            }

            let content = match state.tmux.capture_pane(&pane.id, false).await {
                Ok(c) => c,
                Err(_) => continue,
            };

            let hash = content_hash(&content);
            let ps = self.panes.entry(pane.id.clone()).or_insert(PaneState {
                prev_hash: String::new(),
                was_active: false,
                notified: true, // start as "already notified" so we don't fire on first sight
            });

            let content_changed = ps.prev_hash != hash;
            ps.prev_hash = hash;

            if content_changed {
                // Content is changing → Claude is working
                ps.was_active = true;
                ps.notified = false;
            } else if ps.was_active && !ps.notified {
                // Content just stabilized after being active → transition to idle
                // Check if there's actually a prompt visible
                if detect_prompt(&content).is_some() {
                    ps.was_active = false;
                    ps.notified = true;

                    if !in_warmup {
                        info!(pane_id = %pane.id, session = %session_name, "session became idle, sending notification");
                        let title = session_name.clone();
                        let body = "Session finished".to_string();
                        for token in &tokens {
                            self.apns
                                .send(token, &title, &body, &pane.id, &session_name, "task_complete")
                                .await;
                        }
                    }
                }
            }
        }
    }

    pub fn debug_state(&self) -> serde_json::Value {
        let panes: serde_json::Map<String, serde_json::Value> = self
            .panes
            .iter()
            .map(|(k, v)| {
                (
                    k.clone(),
                    serde_json::json!({
                        "was_active": v.was_active,
                        "notified": v.notified,
                    }),
                )
            })
            .collect();

        serde_json::json!({
            "apns_configured": self.apns.is_configured(),
            "warmup_remaining": self.warmup_remaining,
            "panes": panes,
        })
    }

    pub async fn send_test(&self, tokens: &[String]) {
        for token in tokens {
            self.apns
                .send(token, "Marmy Test", "Push notifications are working!", "", "", "test")
                .await;
        }
    }
}

fn is_claude_process(cmd: &str) -> bool {
    cmd.contains("claude") || cmd.chars().next().map_or(false, |c| c.is_ascii_digit())
}

fn is_shell_process(cmd: &str) -> bool {
    matches!(cmd, "zsh" | "bash" | "fish" | "sh")
}

fn content_hash(content: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(content.as_bytes());
    format!("{:x}", hasher.finalize())
}

fn detect_prompt(content: &str) -> Option<String> {
    let last_lines: Vec<&str> = content.lines().rev().take(10).collect();
    let tail = last_lines.iter().rev().cloned().collect::<Vec<_>>().join("\n");

    // Strip ANSI escape sequences for pattern matching
    let clean = strip_ansi(&tail);

    // Claude Code idle prompt: line containing just "❯" (U+276F) or "> "
    if clean.contains('\u{276F}') || clean.trim_end().ends_with("> ") || clean.trim_end().ends_with(">") {
        return Some("Ready for next task".to_string());
    }
    // Claude Code permission prompt: "bypass permissions" or "Allow"
    if clean.contains("bypass permissions") || clean.contains("Allow ") {
        // Only if it looks like it's waiting (not mid-execution)
        if !clean.contains("Running") && !clean.contains("Wandering") {
            return Some("Permission requested".to_string());
        }
    }
    if clean.contains("Do you want to") {
        return Some("Confirmation needed".to_string());
    }
    if clean.contains("(y/n)") || clean.contains("(Y/n)") || clean.contains("(y/N)") {
        return Some("Yes/no question".to_string());
    }

    None
}

fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\x1b' {
            // Skip ESC [ ... final_byte sequences (CSI)
            if chars.peek() == Some(&'[') {
                chars.next();
                while let Some(&nc) = chars.peek() {
                    chars.next();
                    if nc.is_ascii_alphabetic() || nc == 'm' {
                        break;
                    }
                }
            // Skip ESC ] ... ST sequences (OSC)
            } else if chars.peek() == Some(&']') {
                chars.next();
                while let Some(&nc) = chars.peek() {
                    chars.next();
                    if nc == '\x07' || nc == '\\' {
                        break;
                    }
                }
            }
        } else {
            out.push(c);
        }
    }
    out
}

// --- APNs direct push via HTTP/2 + JWT ---

struct ApnsClient {
    key_id: String,
    team_id: String,
    topic: String,
    sandbox: bool,
    /// PEM bytes of the .p8 key, loaded once on startup
    key_pem: Option<Vec<u8>>,
    /// Cached JWT + creation time (APNs JWTs valid for 1 hour, we refresh at 50 min)
    cached_jwt: Mutex<Option<(String, Instant)>>,
    http: reqwest::Client,
}

impl ApnsClient {
    fn new(config: &NotificationsConfig) -> Self {
        let key_pem = if !config.apns_key_path.is_empty() {
            let path = expand_tilde(&config.apns_key_path);
            match std::fs::read(&path) {
                Ok(bytes) => {
                    info!("loaded APNs key from {}", path.display());
                    Some(bytes)
                }
                Err(e) => {
                    warn!("failed to read APNs key at {}: {}", path.display(), e);
                    None
                }
            }
        } else {
            None
        };

        Self {
            key_id: config.apns_key_id.clone(),
            team_id: config.apns_team_id.clone(),
            topic: config.apns_topic.clone(),
            sandbox: config.apns_sandbox,
            key_pem,
            cached_jwt: Mutex::new(None),
            http: reqwest::Client::builder()
                .http2_prior_knowledge()
                .build()
                .unwrap_or_else(|_| reqwest::Client::new()),
        }
    }

    fn is_configured(&self) -> bool {
        self.key_pem.is_some() && !self.key_id.is_empty() && !self.team_id.is_empty()
    }

    fn get_jwt(&self) -> Option<String> {
        {
            let cache = self.cached_jwt.lock().ok()?;
            if let Some((ref jwt, ref created)) = *cache {
                if created.elapsed() < Duration::from_secs(50 * 60) {
                    return Some(jwt.clone());
                }
            }
        }

        let key_pem = self.key_pem.as_ref()?;
        let now = SystemTime::now().duration_since(UNIX_EPOCH).ok()?.as_secs();

        let header = jsonwebtoken::Header {
            alg: jsonwebtoken::Algorithm::ES256,
            kid: Some(self.key_id.clone()),
            ..Default::default()
        };

        let claims = serde_json::json!({ "iss": self.team_id, "iat": now });
        let encoding_key = jsonwebtoken::EncodingKey::from_ec_pem(key_pem).ok()?;
        let jwt = jsonwebtoken::encode(&header, &claims, &encoding_key).ok()?;

        if let Ok(mut cache) = self.cached_jwt.lock() {
            *cache = Some((jwt.clone(), Instant::now()));
        }

        Some(jwt)
    }

    async fn send(
        &self,
        device_token: &str,
        title: &str,
        body: &str,
        pane_id: &str,
        session_name: &str,
        event_type: &str,
    ) {
        let jwt = match self.get_jwt() {
            Some(j) => j,
            None => {
                error!("failed to generate APNs JWT — check key config");
                return;
            }
        };

        let host = if self.sandbox {
            "api.sandbox.push.apple.com"
        } else {
            "api.push.apple.com"
        };

        let url = format!("https://{}/3/device/{}", host, device_token);

        let payload = serde_json::json!({
            "aps": {
                "alert": { "title": title, "body": body },
                "sound": "default",
            },
            "pane_id": pane_id,
            "session_name": session_name,
            "event": event_type,
        });

        let result = self
            .http
            .post(&url)
            .header("authorization", format!("bearer {}", jwt))
            .header("apns-topic", &self.topic)
            .header("apns-push-type", "alert")
            .header("apns-priority", "10")
            .json(&payload)
            .send()
            .await;

        match result {
            Ok(resp) => {
                let status = resp.status();
                if !status.is_success() {
                    let body_text = resp.text().await.unwrap_or_default();
                    warn!("APNs returned {} : {}", status, body_text);
                } else {
                    info!("APNs push sent successfully");
                }
            }
            Err(e) => {
                error!("failed to send APNs push: {}", e);
            }
        }
    }
}

fn expand_tilde(path: &str) -> PathBuf {
    if path.starts_with("~/") {
        if let Some(home) = dirs::home_dir() {
            return home.join(&path[2..]);
        }
    }
    PathBuf::from(path)
}

// --- Push token persistence ---

fn tokens_path() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("~"))
        .join(".marmy")
        .join("push_tokens.json")
}

pub fn load_push_tokens() -> Vec<String> {
    let path = tokens_path();
    if !path.exists() {
        return Vec::new();
    }
    match std::fs::read_to_string(&path) {
        Ok(content) => {
            let val: serde_json::Value = serde_json::from_str(&content).unwrap_or_default();
            val.get("tokens")
                .and_then(|t| t.as_array())
                .map(|arr| {
                    arr.iter()
                        .filter_map(|v| v.as_str().map(|s| s.to_string()))
                        .collect()
                })
                .unwrap_or_default()
        }
        Err(_) => Vec::new(),
    }
}

pub fn save_push_tokens(tokens: &[String]) {
    let path = tokens_path();
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let val = serde_json::json!({ "tokens": tokens });
    if let Ok(content) = serde_json::to_string_pretty(&val) {
        let _ = std::fs::write(&path, content);
    }
}
