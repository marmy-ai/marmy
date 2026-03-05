use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use tracing::{error, info, warn};

use crate::config::NotificationsConfig;
use crate::state::AppState;

/// Consecutive polls required to flip S(x) in either direction.
const THRESHOLD: u32 = 3;

/// Per-session state S(x).
///   S(x) = false (0): idle / boot state. No notification on entering this state at boot.
///   S(x) = true  (1): active — Claude is working.
/// Notification fires only on the 1→0 edge (active → idle).
struct SessionState {
    /// S(x): true = active, false = idle. Starts false.
    active: bool,
    /// Consecutive polls in the direction opposite to current state.
    streak: u32,
}

pub struct NotificationDetector {
    sessions: HashMap<String, SessionState>,
    apns: ApnsClient,
}

impl NotificationDetector {
    pub fn new(config: &NotificationsConfig) -> Self {
        Self {
            sessions: HashMap::new(),
            apns: ApnsClient::new(config),
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

        let topology = match state.get_topology().await {
            Ok(t) => t,
            Err(_) => return,
        };

        // Single ps call: get CPU of every child process, keyed by parent PID.
        let cpu_by_ppid = get_all_child_cpu().await;

        // Collect the pane IDs we visit so we can prune stale sessions after.
        let mut seen_sessions = Vec::new();

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
                self.sessions.remove(&pane.id);
                continue;
            }

            seen_sessions.push(pane.id.clone());

            // Look up CPU for the Claude child of this pane's shell.
            let cpu_active = match cpu_by_ppid.get(&pane.pid) {
                Some(&cpu) => cpu > 0.0,
                None => continue, // no Claude child found — skip this cycle
            };

            let ss = self.sessions.entry(pane.id.clone()).or_insert(SessionState {
                active: false, // S(x) = 0 on boot
                streak: 0,
            });

            if cpu_active && !ss.active {
                // Currently idle, seeing activity
                ss.streak += 1;
                if ss.streak >= THRESHOLD {
                    ss.active = true; // S(x) = 1. No notification.
                    ss.streak = 0;
                    info!(pane_id = %pane.id, session = %session_name, "session became active");
                }
            } else if !cpu_active && ss.active {
                // Currently active, seeing idle
                ss.streak += 1;
                if ss.streak >= THRESHOLD {
                    ss.active = false; // S(x) = 0. Fire notification.
                    ss.streak = 0;
                    info!(pane_id = %pane.id, session = %session_name, "session became idle, sending notification");
                    let title = session_name.clone();
                    let body = "Session finished".to_string();
                    for token in &tokens {
                        self.apns
                            .send(token, &title, &body, &pane.id, &session_name, "task_complete")
                            .await;
                    }
                }
            } else {
                // Reading matches current state — reset streak
                ss.streak = 0;
            }
        }

        // Prune sessions for panes that no longer exist
        self.sessions.retain(|id, _| seen_sessions.contains(id));
    }

    pub fn debug_state(&self) -> serde_json::Value {
        let sessions: serde_json::Map<String, serde_json::Value> = self
            .sessions
            .iter()
            .map(|(k, v)| {
                (
                    k.clone(),
                    serde_json::json!({
                        "active": v.active,
                        "streak": v.streak,
                    }),
                )
            })
            .collect();

        serde_json::json!({
            "apns_configured": self.apns.is_configured(),
            "sessions": sessions,
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

/// Single `ps` call: returns a map of parent_pid → child_cpu for every process.
/// Each pane shell PID can then look up its Claude child's CPU in O(1).
async fn get_all_child_cpu() -> HashMap<u32, f32> {
    let output = tokio::process::Command::new("ps")
        .args(["-eo", "ppid=,%cpu="])
        .output()
        .await;

    let output = match output {
        Ok(o) if o.status.success() => o,
        _ => return HashMap::new(),
    };

    let text = String::from_utf8_lossy(&output.stdout);
    text.lines()
        .filter_map(|line| {
            let mut parts = line.split_whitespace();
            let ppid: u32 = parts.next()?.parse().ok()?;
            let cpu: f32 = parts.next()?.parse().ok()?;
            Some((ppid, cpu))
        })
        .collect()
}

fn is_claude_process(cmd: &str) -> bool {
    cmd.contains("claude") || cmd.chars().next().map_or(false, |c| c.is_ascii_digit())
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
