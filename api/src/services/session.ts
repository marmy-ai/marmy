import { writeFile, access } from 'fs/promises';
import { join } from 'path';
import { config } from '../config.js';
import { logger } from '../utils/logger.js';
import { tmuxService } from './tmux.js';
import { projectService } from './project.js';
import type { Session, SessionContent } from '../types/session.js';

const CLAUDE_MD_CONTENT = `# Project Rules

## Git Workflow
- NEVER commit directly to main or master
- Create a branch before making changes: \`claude/<description>\`
- NEVER merge branches - leave that to humans
- Always commit your changes before stopping
`;

class SessionService {
  async listSessions(): Promise<Session[]> {
    const tmuxSessions = await tmuxService.listSessions();
    const sessions: Session[] = [];

    for (const ts of tmuxSessions) {
      const projectPath = projectService.getProjectPath(ts.name);
      const projectExists = await projectService.projectExists(ts.name);

      sessions.push({
        id: ts.name,
        projectName: ts.name,
        projectPath: projectExists ? projectPath : '',
        created: new Date(ts.created).toISOString(),
        attached: ts.attached,
        lastActivity: new Date(ts.lastActivity).toISOString(),
      });
    }

    return sessions;
  }

  async getSession(id: string): Promise<Session | null> {
    const sessions = await this.listSessions();
    return sessions.find((s) => s.id === id) || null;
  }

  async getSessionContent(id: string): Promise<SessionContent> {
    const content = await tmuxService.capturePane(id);
    return {
      sessionId: id,
      content,
      timestamp: new Date().toISOString(),
    };
  }

  async ensureSession(projectName: string): Promise<Session> {
    // Check if session already exists
    const existingSession = await this.getSession(projectName);
    if (existingSession) {
      return existingSession;
    }

    // Verify project exists
    const project = await projectService.getProject(projectName);
    if (!project) {
      throw new Error(`Project '${projectName}' not found`);
    }

    // Verify git is initialized
    if (!project.hasGit) {
      throw new Error(`Project '${projectName}' has no git initialized`);
    }

    // Ensure CLAUDE.md exists
    await this.ensureClaudeMd(project.path);

    // Create the tmux session
    await tmuxService.createSession(projectName, project.path);

    // Start Claude Code in the session
    await this.startClaudeCode(projectName);

    // Return the new session
    const session = await this.getSession(projectName);
    if (!session) {
      throw new Error('Failed to create session');
    }

    return session;
  }

  async submitToSession(id: string, text: string): Promise<void> {
    // Ensure session exists (lazy creation based on project name)
    await this.ensureSession(id);

    // Send text to the session
    await tmuxService.sendText(id, text, true);
  }

  async killSession(id: string): Promise<void> {
    const exists = await tmuxService.sessionExists(id);
    if (!exists) {
      throw new Error(`Session '${id}' not found`);
    }

    await tmuxService.killSession(id);
  }

  private async ensureClaudeMd(projectPath: string): Promise<void> {
    const claudeMdPath = join(projectPath, 'CLAUDE.md');

    try {
      await access(claudeMdPath);
      logger.debug('CLAUDE.md already exists', { projectPath });
    } catch {
      logger.info('Creating CLAUDE.md', { projectPath });
      await writeFile(claudeMdPath, CLAUDE_MD_CONTENT, 'utf8');
    }
  }

  private async startClaudeCode(sessionName: string): Promise<void> {
    const claudeCommand = config.claude.command;
    logger.info(`Starting Claude Code in session: ${sessionName}`);

    // Wait a brief moment for the shell to initialize
    await new Promise((resolve) => setTimeout(resolve, 500));

    // Send the claude command
    await tmuxService.sendText(sessionName, claudeCommand, true);
  }
}

export const sessionService = new SessionService();
