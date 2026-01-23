export interface Session {
  id: string;
  projectName: string;
  projectPath: string;
  created: string;
  attached: boolean;
  lastActivity: string;
}

export interface SessionContent {
  sessionId: string;
  content: string;
  timestamp: string;
}

export interface TmuxSession {
  name: string;
  created: number;
  attached: boolean;
  lastActivity: number;
}
