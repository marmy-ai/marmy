use std::path::PathBuf;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    #[serde(default = "default_server")]
    pub server: ServerConfig,
    #[serde(default)]
    pub auth: AuthConfig,
    #[serde(default)]
    pub files: FilesConfig,
    #[serde(default)]
    pub tmux: TmuxConfig,
    #[serde(default)]
    pub notifications: NotificationsConfig,
    #[serde(default)]
    pub voice: VoiceConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerConfig {
    #[serde(default = "default_bind")]
    pub bind: String,
    #[serde(default = "default_port")]
    pub port: u16,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuthConfig {
    /// Bearer token for API authentication. Auto-generated on first run.
    #[serde(default)]
    pub token: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FilesConfig {
    /// Directories the mobile client is allowed to browse.
    /// Empty means no file browsing (safe default).
    #[serde(default)]
    pub allowed_paths: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TmuxConfig {
    /// tmux socket name (-L flag). Empty means default socket.
    #[serde(default)]
    pub socket_name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NotificationsConfig {
    #[serde(default = "default_notifications_enabled")]
    pub enabled: bool,
    #[serde(default = "default_cooldown_seconds")]
    pub cooldown_seconds: u64,
    /// Path to APNs .p8 key file (from Apple Developer > Keys)
    #[serde(default)]
    pub apns_key_path: String,
    /// APNs Key ID (10-char string from Apple Developer)
    #[serde(default)]
    pub apns_key_id: String,
    /// Apple Developer Team ID
    #[serde(default)]
    pub apns_team_id: String,
    /// APNs topic — your app's bundle identifier
    #[serde(default = "default_apns_topic")]
    pub apns_topic: String,
    /// Use APNs sandbox (true for dev builds, false for production)
    #[serde(default = "default_apns_sandbox")]
    pub apns_sandbox: bool,
    /// Relay URL for App Store builds. When set, tokens with provider "relay"
    /// are forwarded here instead of using the local APNs key.
    #[serde(default = "default_relay_url")]
    pub relay_url: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VoiceConfig {
    /// Gemini API key for voice mode.
    #[serde(default)]
    pub gemini_api_key: String,
}

impl Default for VoiceConfig {
    fn default() -> Self {
        Self {
            gemini_api_key: String::new(),
        }
    }
}

fn default_notifications_enabled() -> bool {
    true
}

fn default_cooldown_seconds() -> u64 {
    120
}

fn default_apns_topic() -> String {
    "com.marmy.app".to_string()
}

fn default_apns_sandbox() -> bool {
    true
}

fn default_relay_url() -> String {
    "https://tloo7bj5rmnw3bmvvveqo7immi0pmhhb.lambda-url.us-west-2.on.aws/".to_string()
}

fn default_server() -> ServerConfig {
    ServerConfig {
        bind: default_bind(),
        port: default_port(),
    }
}

fn default_bind() -> String {
    "0.0.0.0".to_string()
}

fn default_port() -> u16 {
    9876
}

impl Default for Config {
    fn default() -> Self {
        Self {
            server: default_server(),
            auth: AuthConfig {
                token: String::new(),
            },
            files: FilesConfig {
                allowed_paths: Vec::new(),
            },
            tmux: TmuxConfig {
                socket_name: String::new(),
            },
            notifications: NotificationsConfig::default(),
            voice: VoiceConfig::default(),
        }
    }
}

impl Default for ServerConfig {
    fn default() -> Self {
        default_server()
    }
}

impl Default for AuthConfig {
    fn default() -> Self {
        Self {
            token: String::new(),
        }
    }
}

impl Default for FilesConfig {
    fn default() -> Self {
        Self {
            allowed_paths: Vec::new(),
        }
    }
}

impl Default for TmuxConfig {
    fn default() -> Self {
        Self {
            socket_name: String::new(),
        }
    }
}

impl Default for NotificationsConfig {
    fn default() -> Self {
        Self {
            enabled: default_notifications_enabled(),
            cooldown_seconds: default_cooldown_seconds(),
            apns_key_path: String::new(),
            apns_key_id: String::new(),
            apns_team_id: String::new(),
            apns_topic: default_apns_topic(),
            apns_sandbox: default_apns_sandbox(),
            relay_url: default_relay_url(),
        }
    }
}

impl Config {
    /// Load config from `~/.config/marmy/config.toml`, creating defaults if missing.
    pub fn load() -> Result<Self> {
        let path = config_path();

        if path.exists() {
            let content =
                std::fs::read_to_string(&path).context("failed to read config file")?;
            let mut config: Config =
                toml::from_str(&content).context("failed to parse config file")?;

            // Generate token if empty
            if config.auth.token.is_empty() {
                config.auth.token = generate_token();
                config.save()?;
            }

            Ok(config)
        } else {
            let mut config = Config::default();
            config.auth.token = generate_token();
            config.save()?;
            Ok(config)
        }
    }

    /// Save config to disk.
    pub fn save(&self) -> Result<()> {
        let path = config_path();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).context("failed to create config directory")?;
        }
        let content = toml::to_string_pretty(self).context("failed to serialize config")?;
        std::fs::write(&path, content).context("failed to write config file")?;
        Ok(())
    }
}

pub fn config_path() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from("~/.config"))
        .join("marmy")
        .join("config.toml")
}

fn generate_token() -> String {
    use rand::Rng;
    let mut rng = rand::thread_rng();
    let bytes: Vec<u8> = (0..32).map(|_| rng.gen()).collect();
    base64::Engine::encode(&base64::engine::general_purpose::URL_SAFE_NO_PAD, &bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    // --- generate_token ---

    #[test]
    fn generate_token_is_nonempty() {
        let token = generate_token();
        assert!(!token.is_empty());
    }

    #[test]
    fn generate_token_is_valid_base64url() {
        let token = generate_token();
        // base64url uses A-Z, a-z, 0-9, -, _ (no padding since URL_SAFE_NO_PAD)
        assert!(token.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'));
    }

    #[test]
    fn generate_token_is_unique() {
        let t1 = generate_token();
        let t2 = generate_token();
        assert_ne!(t1, t2);
    }

    #[test]
    fn generate_token_length_from_32_bytes() {
        // 32 bytes base64-encoded (no padding) = ceil(32*4/3) = 43 chars
        let token = generate_token();
        assert_eq!(token.len(), 43);
    }

    // --- Config defaults ---

    #[test]
    fn default_config_has_expected_values() {
        let config = Config::default();
        assert_eq!(config.server.bind, "0.0.0.0");
        assert_eq!(config.server.port, 9876);
        assert!(config.auth.token.is_empty());
        assert!(config.files.allowed_paths.is_empty());
        assert!(config.tmux.socket_name.is_empty());
        assert!(config.notifications.enabled);
        assert_eq!(config.notifications.cooldown_seconds, 120);
        assert!(config.notifications.apns_sandbox);
        assert_eq!(config.notifications.apns_topic, "com.marmy.app");
        assert!(config.notifications.relay_url.starts_with("https://"));
        assert!(config.voice.gemini_api_key.is_empty());
    }

    // --- TOML serialization roundtrip ---

    #[test]
    fn config_toml_roundtrip() {
        let mut config = Config::default();
        config.auth.token = "test-token-123".to_string();
        config.server.port = 8888;
        config.files.allowed_paths = vec!["~/projects".to_string()];

        let toml_str = toml::to_string_pretty(&config).unwrap();
        let loaded: Config = toml::from_str(&toml_str).unwrap();

        assert_eq!(loaded.auth.token, "test-token-123");
        assert_eq!(loaded.server.port, 8888);
        assert_eq!(loaded.files.allowed_paths, vec!["~/projects"]);
        // Defaults should survive the roundtrip
        assert_eq!(loaded.server.bind, "0.0.0.0");
        assert!(loaded.notifications.enabled);
    }

    #[test]
    fn config_loads_from_partial_toml() {
        // Users often have minimal configs — missing sections should use defaults
        let partial = r#"
[auth]
token = "my-token"
"#;
        let config: Config = toml::from_str(partial).unwrap();
        assert_eq!(config.auth.token, "my-token");
        assert_eq!(config.server.port, 9876); // default
        assert!(config.files.allowed_paths.is_empty()); // default
    }

    #[test]
    fn config_save_and_read_from_temp_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");

        let mut config = Config::default();
        config.auth.token = "save-test".to_string();
        config.server.port = 7777;

        // Save
        let content = toml::to_string_pretty(&config).unwrap();
        std::fs::write(&path, &content).unwrap();

        // Read back
        let read_content = std::fs::read_to_string(&path).unwrap();
        let loaded: Config = toml::from_str(&read_content).unwrap();
        assert_eq!(loaded.auth.token, "save-test");
        assert_eq!(loaded.server.port, 7777);
    }

    // --- config_path ---

    #[test]
    fn config_path_ends_with_expected_components() {
        let path = config_path();
        assert!(path.ends_with("marmy/config.toml"));
    }
}
