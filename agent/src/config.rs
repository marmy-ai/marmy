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
