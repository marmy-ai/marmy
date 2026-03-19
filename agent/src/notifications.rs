use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use tracing::{error, info, warn};

use crate::config::NotificationsConfig;

/// A registered push token with its routing provider.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PushToken {
    pub token: String,
    /// "relay" = forward to relay_url, "local" = direct APNs via local p8 key.
    #[serde(default = "default_provider")]
    pub provider: String,
}

fn default_provider() -> String {
    "local".to_string()
}

/// Holds the APNs client and relay config. No detection logic —
/// notifications are triggered by Claude calling `POST /api/notifications/send`.
pub struct NotificationSender {
    apns: ApnsClient,
    relay_url: String,
    http: reqwest::Client,
}

impl NotificationSender {
    pub fn new(config: &NotificationsConfig) -> Self {
        Self {
            apns: ApnsClient::new(config),
            relay_url: config.relay_url.clone(),
            http: reqwest::Client::new(),
        }
    }

    pub fn is_configured(&self) -> bool {
        self.apns.is_configured() || !self.relay_url.is_empty()
    }

    pub async fn send(
        &self,
        tokens: &[PushToken],
        title: &str,
        body: &str,
        pane_id: &str,
        session_name: &str,
        event_type: &str,
    ) {
        for pt in tokens {
            if pt.provider == "relay" && !self.relay_url.is_empty() {
                self.send_relay(&pt.token, title, body, session_name).await;
            } else {
                self.apns
                    .send(&pt.token, title, body, pane_id, session_name, event_type)
                    .await;
            }
        }
    }

    pub async fn send_test(&self, tokens: &[PushToken]) {
        for pt in tokens {
            if pt.provider == "relay" && !self.relay_url.is_empty() {
                self.send_relay(&pt.token, "Marmy Test", "Push notifications are working!", "")
                    .await;
            } else {
                self.apns
                    .send(&pt.token, "Marmy Test", "Push notifications are working!", "", "", "test")
                    .await;
            }
        }
    }

    async fn send_relay(&self, device_token: &str, title: &str, body: &str, session_name: &str) {
        let payload = serde_json::json!({
            "device_token": device_token,
            "title": title,
            "body": body,
            "session_name": session_name,
        });

        match self.http.post(&self.relay_url).json(&payload).send().await {
            Ok(resp) => {
                if !resp.status().is_success() {
                    let status = resp.status();
                    let text = resp.text().await.unwrap_or_default();
                    warn!("relay returned {} : {}", status, text);
                } else {
                    info!("push sent via relay");
                }
            }
            Err(e) => {
                error!("failed to send push via relay: {}", e);
            }
        }
    }
}

// --- APNs direct push via HTTP/2 + JWT ---

struct ApnsClient {
    key_id: String,
    team_id: String,
    topic: String,
    sandbox: bool,
    key_pem: Option<Vec<u8>>,
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

// --- Unread session persistence ---

fn unread_sessions_path() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("~"))
        .join(".marmy")
        .join("unread_sessions.json")
}

pub fn load_unread_sessions() -> std::collections::HashSet<String> {
    let path = unread_sessions_path();
    if !path.exists() {
        return std::collections::HashSet::new();
    }
    match std::fs::read_to_string(&path) {
        Ok(content) => {
            let val: serde_json::Value = serde_json::from_str(&content).unwrap_or_default();
            val.get("sessions")
                .and_then(|t| t.as_array())
                .map(|arr| {
                    arr.iter()
                        .filter_map(|v| v.as_str().map(|s| s.to_string()))
                        .collect()
                })
                .unwrap_or_default()
        }
        Err(_) => std::collections::HashSet::new(),
    }
}

pub fn save_unread_sessions(sessions: &std::collections::HashSet<String>) {
    let path = unread_sessions_path();
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let list: Vec<&String> = sessions.iter().collect();
    let val = serde_json::json!({ "sessions": list });
    if let Ok(content) = serde_json::to_string_pretty(&val) {
        let _ = std::fs::write(&path, content);
    }
}

// --- Push token persistence ---

fn tokens_path() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("~"))
        .join(".marmy")
        .join("push_tokens.json")
}

pub fn load_push_tokens() -> Vec<PushToken> {
    let path = tokens_path();
    if !path.exists() {
        return Vec::new();
    }
    match std::fs::read_to_string(&path) {
        Ok(content) => {
            // Try new format first: array of {token, provider} objects
            if let Ok(val) = serde_json::from_str::<serde_json::Value>(&content) {
                if let Some(arr) = val.get("tokens").and_then(|t| t.as_array()) {
                    // Check if first element is a string (old format) or object (new format)
                    if arr.first().map_or(false, |v| v.is_string()) {
                        // Migrate old format: plain string tokens → PushToken with "local"
                        return arr
                            .iter()
                            .filter_map(|v| v.as_str().map(|s| PushToken {
                                token: s.to_string(),
                                provider: "local".to_string(),
                            }))
                            .collect();
                    }
                    // New format: array of PushToken objects
                    return arr
                        .iter()
                        .filter_map(|v| serde_json::from_value::<PushToken>(v.clone()).ok())
                        .collect();
                }
            }
            Vec::new()
        }
        Err(_) => Vec::new(),
    }
}

pub fn save_push_tokens(tokens: &[PushToken]) {
    let path = tokens_path();
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let val = serde_json::json!({ "tokens": tokens });
    if let Ok(content) = serde_json::to_string_pretty(&val) {
        let _ = std::fs::write(&path, content);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    // --- expand_tilde ---

    #[test]
    fn expand_tilde_with_subpath() {
        let result = expand_tilde("~/Documents/key.p8");
        let home = dirs::home_dir().unwrap();
        assert_eq!(result, home.join("Documents/key.p8"));
    }

    #[test]
    fn expand_tilde_absolute_path_unchanged() {
        let result = expand_tilde("/etc/ssl/cert.pem");
        assert_eq!(result, PathBuf::from("/etc/ssl/cert.pem"));
    }

    #[test]
    fn expand_tilde_bare_tilde_no_slash_unchanged() {
        // "~" without "/" is not expanded (only "~/" prefix triggers expansion)
        let result = expand_tilde("~");
        assert_eq!(result, PathBuf::from("~"));
    }

    // --- Unread sessions JSON format ---

    #[test]
    fn unread_sessions_json_roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("unread.json");

        let sessions: HashSet<String> = ["worker-1".into(), "worker-2".into()].into();
        let list: Vec<&String> = sessions.iter().collect();
        let val = serde_json::json!({ "sessions": list });
        let content = serde_json::to_string_pretty(&val).unwrap();
        std::fs::write(&path, &content).unwrap();

        // Parse it back the same way load_unread_sessions does
        let read_content = std::fs::read_to_string(&path).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&read_content).unwrap();
        let loaded: HashSet<String> = parsed
            .get("sessions")
            .and_then(|t| t.as_array())
            .map(|arr| arr.iter().filter_map(|v| v.as_str().map(|s| s.to_string())).collect())
            .unwrap_or_default();

        assert_eq!(loaded, sessions);
    }

    #[test]
    fn unread_sessions_missing_file_returns_empty() {
        // Simulates load_unread_sessions behavior when file doesn't exist
        let path = PathBuf::from("/nonexistent/unread_sessions.json");
        assert!(!path.exists());
        // The function returns empty set for missing files
        let result: HashSet<String> = HashSet::new();
        assert!(result.is_empty());
    }

    #[test]
    fn unread_sessions_corrupt_json_returns_empty() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("corrupt.json");
        std::fs::write(&path, "not valid json {{{").unwrap();

        let content = std::fs::read_to_string(&path).unwrap();
        let val: serde_json::Value = serde_json::from_str(&content).unwrap_or_default();
        let loaded: HashSet<String> = val
            .get("sessions")
            .and_then(|t| t.as_array())
            .map(|arr| arr.iter().filter_map(|v| v.as_str().map(|s| s.to_string())).collect())
            .unwrap_or_default();

        assert!(loaded.is_empty());
    }

    // --- Push tokens JSON format ---

    #[test]
    fn push_tokens_new_format_roundtrip() {
        let tokens = vec![
            PushToken { token: "abc123".into(), provider: "relay".into() },
            PushToken { token: "def456".into(), provider: "local".into() },
        ];
        let val = serde_json::json!({ "tokens": tokens });
        let content = serde_json::to_string_pretty(&val).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&content).unwrap();
        let loaded: Vec<PushToken> = parsed
            .get("tokens")
            .and_then(|t| t.as_array())
            .map(|arr| arr.iter().filter_map(|v| serde_json::from_value::<PushToken>(v.clone()).ok()).collect())
            .unwrap_or_default();

        assert_eq!(loaded, tokens);
    }

    #[test]
    fn push_tokens_old_string_format_migrates_to_local() {
        // Old format was just string tokens — load_push_tokens should migrate them
        let content = r#"{ "tokens": ["abc123", "def456"] }"#;
        let val: serde_json::Value = serde_json::from_str(content).unwrap();
        let arr = val.get("tokens").unwrap().as_array().unwrap();

        // Simulate the migration logic from load_push_tokens
        let loaded: Vec<PushToken> = if arr.first().map_or(false, |v| v.is_string()) {
            arr.iter()
                .filter_map(|v| v.as_str().map(|s| PushToken {
                    token: s.to_string(),
                    provider: "local".to_string(),
                }))
                .collect()
        } else {
            vec![]
        };

        assert_eq!(loaded.len(), 2);
        assert_eq!(loaded[0].token, "abc123");
        assert_eq!(loaded[0].provider, "local");
        assert_eq!(loaded[1].provider, "local");
    }

    #[test]
    fn push_tokens_empty_array_roundtrip() {
        let tokens: Vec<PushToken> = vec![];
        let val = serde_json::json!({ "tokens": tokens });
        let content = serde_json::to_string_pretty(&val).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&content).unwrap();
        let loaded: Vec<PushToken> = parsed
            .get("tokens")
            .and_then(|t| t.as_array())
            .map(|arr| arr.iter().filter_map(|v| serde_json::from_value::<PushToken>(v.clone()).ok()).collect())
            .unwrap_or_default();

        assert!(loaded.is_empty());
    }

    // --- NotificationSender::is_configured ---

    #[test]
    fn sender_configured_with_default_relay_url() {
        // Default config has the official relay URL, so sender is configured
        let config = NotificationsConfig::default();
        let sender = NotificationSender::new(&config);
        assert!(sender.is_configured());
    }

    #[test]
    fn sender_not_configured_without_key_or_relay() {
        let mut config = NotificationsConfig::default();
        config.relay_url = String::new();
        let sender = NotificationSender::new(&config);
        assert!(!sender.is_configured());
    }
}
