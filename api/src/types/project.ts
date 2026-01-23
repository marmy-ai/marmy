export interface Project {
  name: string;
  path: string;
  hasGit: boolean;
  gitBranch: string | null;
  hasSession: boolean;
  sessionId: string | null;
}
