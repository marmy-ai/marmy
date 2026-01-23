import { readdir, stat, access } from 'fs/promises';
import { join } from 'path';
import { config } from '../config.js';
import { exec } from '../utils/exec.js';
import { logger } from '../utils/logger.js';
import { tmuxService } from './tmux.js';
import type { Project } from '../types/project.js';

class ProjectService {
  async listProjects(): Promise<Project[]> {
    const workspacePath = config.workspace.path;
    const excludeList = config.workspace.exclude;

    try {
      const entries = await readdir(workspacePath, { withFileTypes: true });
      const activeSessions = await tmuxService.listSessions();
      const sessionNames = new Set(activeSessions.map((s) => s.name));

      const projects: Project[] = [];

      for (const entry of entries) {
        if (!entry.isDirectory()) continue;
        if (excludeList.includes(entry.name)) continue;
        if (entry.name.startsWith('.')) continue;

        const projectPath = join(workspacePath, entry.name);
        const hasGit = await this.hasGit(projectPath);
        const gitBranch = hasGit ? await this.getGitBranch(projectPath) : null;
        const hasSession = sessionNames.has(entry.name);

        projects.push({
          name: entry.name,
          path: projectPath,
          hasGit,
          gitBranch,
          hasSession,
          sessionId: hasSession ? entry.name : null,
        });
      }

      return projects.sort((a, b) => a.name.localeCompare(b.name));
    } catch (error) {
      logger.error('Failed to list projects', { error });
      throw error;
    }
  }

  async getProject(name: string): Promise<Project | null> {
    const projects = await this.listProjects();
    return projects.find((p) => p.name === name) || null;
  }

  async projectExists(name: string): Promise<boolean> {
    const projectPath = join(config.workspace.path, name);
    try {
      const stats = await stat(projectPath);
      return stats.isDirectory();
    } catch {
      return false;
    }
  }

  async hasGit(projectPath: string): Promise<boolean> {
    const gitPath = join(projectPath, '.git');
    try {
      await access(gitPath);
      return true;
    } catch {
      return false;
    }
  }

  async getGitBranch(projectPath: string): Promise<string | null> {
    try {
      const { stdout } = await exec('git branch --show-current', {
        cwd: projectPath,
      });
      return stdout.trim() || null;
    } catch {
      return null;
    }
  }

  getProjectPath(name: string): string {
    return join(config.workspace.path, name);
  }
}

export const projectService = new ProjectService();
