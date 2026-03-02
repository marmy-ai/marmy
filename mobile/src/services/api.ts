import type {
  TmuxTopology,
  PaneContent,
  DirListing,
  FileContent,
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
  async createSession(name: string): Promise<void> {
    await this.fetch("/api/sessions", {
      method: "POST",
      body: JSON.stringify({ name }),
    });
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

  /** Get WebSocket URL for this machine. */
  getWsUrl(): string {
    const wsBase = this.baseUrl
      .replace("http://", "ws://")
      .replace("https://", "wss://");
    return `${wsBase}/ws`;
  }
}
