import type {
  TmuxTopology,
  PaneContent,
  DirListing,
  FileContent,
  SessionRoot,
  CcSession,
  CcSessionContext,
  DashboardStartResponse,
  CreateSessionResponse,
  VoiceTokenResponse,
} from "../types";

export class MarmyApi {
  private baseUrl: string;
  private token: string;

  constructor(address: string, token: string) {
    // Strip trailing slash, ensure http://
    const base = address.replace(/\/$/, "");
    this.baseUrl = base.startsWith("http") ? base : `http://${base}`;
    this.token = token;
  }

  private async fetch<T>(path: string, init?: RequestInit): Promise<T> {
    const res = await fetch(`${this.baseUrl}${path}`, {
      ...init,
      headers: {
        Authorization: `Bearer ${this.token}`,
        "Content-Type": "application/json",
        ...init?.headers,
      },
    });

    if (!res.ok) {
      const text = await res.text().catch(() => res.statusText);
      throw new Error(`API error ${res.status}: ${text}`);
    }

    const text = await res.text();
    if (!text) return undefined as T;
    return JSON.parse(text);
  }

  /** Check if the agent is reachable. */
  async ping(): Promise<boolean> {
    try {
      await this.fetch<TmuxTopology>("/api/sessions");
      return true;
    } catch {
      return false;
    }
  }

  /** Get full tmux topology. */
  async getSessions(): Promise<TmuxTopology> {
    return this.fetch<TmuxTopology>("/api/sessions");
  }

  /** Create a new tmux session. */
  async createSession(
    name: string,
    options?: { mode?: string; working_dir?: string; skip_permissions?: boolean }
  ): Promise<CreateSessionResponse> {
    return this.fetch<CreateSessionResponse>("/api/sessions", {
      method: "POST",
      body: JSON.stringify({ name, ...options }),
    });
  }

  /** Get recent working directories from all panes. */
  async getRecentDirs(): Promise<string[]> {
    return this.fetch<string[]>("/api/sessions/recent-dirs");
  }

  /** Delete (kill) a tmux session. */
  async deleteSession(name: string): Promise<void> {
    await this.fetch(`/api/sessions/${encodeURIComponent(name)}`, {
      method: "DELETE",
    });
  }

  /** Get current pane content (visible screen). */
  async getPaneContent(paneId: string): Promise<PaneContent> {
    const id = paneId.replace("%", "");
    return this.fetch<PaneContent>(`/api/panes/${id}/content`);
  }

  /** Get full scrollback history. */
  async getPaneHistory(paneId: string): Promise<PaneContent> {
    const id = paneId.replace("%", "");
    return this.fetch<PaneContent>(`/api/panes/${id}/history`);
  }

  /** Send input to a pane. */
  async sendInput(
    paneId: string,
    keys: string,
    literal = true
  ): Promise<void> {
    const id = paneId.replace("%", "");
    await this.fetch(`/api/panes/${id}/input`, {
      method: "POST",
      body: JSON.stringify({ keys, literal }),
    });
  }

  /** Resize a pane. */
  async resizPane(
    paneId: string,
    cols: number,
    rows: number
  ): Promise<void> {
    const id = paneId.replace("%", "");
    await this.fetch(`/api/panes/${id}/resize`, {
      method: "POST",
      body: JSON.stringify({ cols, rows }),
    });
  }

  /** Get configured allowed root paths. */
  async getFileRoots(): Promise<string[]> {
    return this.fetch<string[]>("/api/files/roots");
  }

  /** Get working directories for panes in a session. */
  async getSessionRoots(sessionId: string): Promise<SessionRoot[]> {
    return this.fetch<SessionRoot[]>(
      `/api/files/session-roots?session_id=${encodeURIComponent(sessionId)}`
    );
  }

  /** Build full URL for raw file endpoint (for <Image> source). */
  getRawFileUrl(path: string): string {
    return `${this.baseUrl}/api/files/raw?path=${encodeURIComponent(path)}`;
  }

  /** Expose auth headers for components that need them (e.g. <Image>). */
  getAuthHeaders(): Record<string, string> {
    return { Authorization: `Bearer ${this.token}` };
  }

  /** List directory contents. */
  async listDir(path: string): Promise<DirListing> {
    return this.fetch<DirListing>(
      `/api/files/tree?path=${encodeURIComponent(path)}`
    );
  }

  /** Read file contents. */
  async readFile(path: string): Promise<FileContent> {
    return this.fetch<FileContent>(
      `/api/files/content?path=${encodeURIComponent(path)}`
    );
  }

  /** List all discovered CC sessions. */
  async getCcSessions(): Promise<CcSession[]> {
    return this.fetch<CcSession[]>("/api/cc/sessions");
  }

  /** Get context (last inputs + output) for a CC session. */
  async getCcSessionContext(sessionId: string): Promise<CcSessionContext> {
    return this.fetch<CcSessionContext>(
      `/api/cc/sessions/${encodeURIComponent(sessionId)}/context`
    );
  }

  /** Start (or reuse) the dashboard agent session. */
  async startDashboard(): Promise<DashboardStartResponse> {
    return this.fetch<DashboardStartResponse>("/api/cc/dashboard/start", {
      method: "POST",
    });
  }

  /** Register a push notification token with the agent. */
  async registerPushToken(token: string): Promise<void> {
    await this.fetch("/api/notifications/register", {
      method: "POST",
      body: JSON.stringify({ token }),
    });
  }

  /** Unregister a push notification token. */
  async unregisterPushToken(token: string): Promise<void> {
    await this.fetch("/api/notifications/register", {
      method: "DELETE",
      body: JSON.stringify({ token }),
    });
  }

  /** Enable/disable the Claude Code Stop hook for push notifications. */
  async setNotifyHook(enabled: boolean): Promise<void> {
    await this.fetch("/api/notifications/hook", {
      method: "POST",
      body: JSON.stringify({ enabled }),
    });
  }

  /** Check if the notification hook is currently enabled. */
  async getNotifyHookStatus(): Promise<boolean> {
    const debug = await this.fetch<{ hook_enabled: boolean }>("/api/notifications/debug");
    return debug.hook_enabled;
  }

  /** Send a notification (called by Claude via curl, but also available here). */
  async sendNotification(session?: string, body?: string): Promise<void> {
    await this.fetch("/api/notifications/send", {
      method: "POST",
      body: JSON.stringify({ session: session || "", body: body || "" }),
    });
  }

  /** Send a test notification. */
  async testNotification(): Promise<void> {
    await this.fetch("/api/notifications/test", {
      method: "POST",
    });
  }

  /** Get Gemini API key for voice mode. */
  async getVoiceToken(): Promise<VoiceTokenResponse> {
    return this.fetch<VoiceTokenResponse>("/api/voice/token");
  }

  /** Get WebSocket URL for this machine (includes auth token). */
  getWsUrl(): string {
    const wsBase = this.baseUrl
      .replace("http://", "ws://")
      .replace("https://", "wss://");
    return `${wsBase}/ws?token=${encodeURIComponent(this.token)}`;
  }
}
