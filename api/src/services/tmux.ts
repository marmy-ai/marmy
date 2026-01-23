import { exec } from '../utils/exec.js';
import { logger } from '../utils/logger.js';
import { config } from '../config.js';
import type { TmuxSession } from '../types/session.js';

class TmuxService {
  async listSessions(): Promise<TmuxSession[]> {
    try {
      const { stdout } = await exec(
        'tmux list-sessions -F "#{session_name}|#{session_created}|#{session_attached}|#{session_activity}" 2>/dev/null || true'
      );

      if (!stdout.trim()) {
        return [];
      }

      const sessions: TmuxSession[] = [];
      const lines = stdout.trim().split('\n');

      for (const line of lines) {
        const [name, created, attached, activity] = line.split('|');
        if (name) {
          sessions.push({
            name,
            created: parseInt(created, 10) * 1000,
            attached: attached === '1',
            lastActivity: parseInt(activity, 10) * 1000,
          });
        }
      }

      return sessions;
    } catch (error) {
      logger.error('Failed to list tmux sessions', { error });
      return [];
    }
  }

  async sessionExists(name: string): Promise<boolean> {
    try {
      await exec(`tmux has-session -t "${name}" 2>/dev/null`);
      return true;
    } catch {
      return false;
    }
  }

  async createSession(name: string, workingDir: string): Promise<void> {
    const shell = config.tmux.shell;
    logger.info(`Creating tmux session: ${name}`, { workingDir });

    await exec(
      `tmux new-session -d -s "${name}" -c "${workingDir}" "${shell}"`
    );
  }

  async killSession(name: string): Promise<void> {
    logger.info(`Killing tmux session: ${name}`);
    await exec(`tmux kill-session -t "${name}"`);
  }

  async capturePane(session: string, lines?: number): Promise<string> {
    const captureLines = lines || config.tmux.captureLines;
    const { stdout } = await exec(
      `tmux capture-pane -t "${session}" -p -S -${captureLines}`
    );
    return stdout;
  }

  async sendKeys(session: string, keys: string): Promise<void> {
    logger.debug(`Sending keys to session: ${session}`, { keys });
    // Escape special characters for tmux
    const escapedKeys = keys.replace(/"/g, '\\"');
    await exec(`tmux send-keys -t "${session}" "${escapedKeys}"`);
  }

  async sendText(session: string, text: string, submit = true): Promise<void> {
    logger.debug(`Sending text to session: ${session}`, { text, submit });
    // Escape special characters for tmux
    const escapedText = text.replace(/"/g, '\\"');
    if (submit) {
      await exec(`tmux send-keys -t "${session}" "${escapedText}" Enter`);
    } else {
      await exec(`tmux send-keys -t "${session}" "${escapedText}"`);
    }
  }

  async getVersion(): Promise<string> {
    try {
      const { stdout } = await exec('tmux -V');
      return stdout.trim();
    } catch {
      return 'unknown';
    }
  }

  async isInstalled(): Promise<boolean> {
    try {
      await exec('which tmux');
      return true;
    } catch {
      return false;
    }
  }
}

export const tmuxService = new TmuxService();
