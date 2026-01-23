import { readFileSync } from 'fs';
import { parse } from 'yaml';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import dotenv from 'dotenv';

dotenv.config();

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

interface Config {
  server: {
    host: string;
    port: number;
  };
  auth: {
    token: string;
  };
  workspace: {
    path: string;
    exclude: string[];
  };
  tmux: {
    captureLines: number;
    shell: string;
  };
  claude: {
    command: string;
  };
}

function loadConfig(): Config {
  const configPath = join(__dirname, '..', 'config', 'default.yaml');
  const fileContents = readFileSync(configPath, 'utf8');
  const yamlConfig = parse(fileContents) as Config;

  // Apply environment variable overrides
  const config: Config = {
    server: {
      host: process.env.MARMY_HOST || yamlConfig.server.host,
      port: parseInt(process.env.MARMY_PORT || String(yamlConfig.server.port), 10),
    },
    auth: {
      token: process.env.MARMY_AUTH_TOKEN || yamlConfig.auth.token,
    },
    workspace: {
      path: process.env.MARMY_WORKSPACE_PATH || yamlConfig.workspace.path,
      exclude: yamlConfig.workspace.exclude,
    },
    tmux: {
      captureLines: parseInt(process.env.MARMY_TMUX_CAPTURE_LINES || String(yamlConfig.tmux.captureLines), 10),
      shell: yamlConfig.tmux.shell,
    },
    claude: {
      command: process.env.MARMY_CLAUDE_COMMAND || yamlConfig.claude.command,
    },
  };

  return config;
}

export const config = loadConfig();
export type { Config };
