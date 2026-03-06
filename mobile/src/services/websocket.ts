import type { ClientMessage, ServerMessage } from "../types";

type MessageHandler = (msg: ServerMessage) => void;

/**
 * Manages a WebSocket connection to a marmy-agent, with auto-reconnect,
 * heartbeat, resubscription, and message queuing.
 */
export class MarmySocket {
  private ws: WebSocket | null = null;
  private url: string;
  private handlers: Set<MessageHandler> = new Set();
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private reconnectDelay = 1000;
  private maxReconnectDelay = 30000;
  private shouldReconnect = true;

  // Heartbeat
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  private pongTimer: ReturnType<typeof setTimeout> | null = null;

  // Subscription tracking for resubscription on reconnect
  private subscribedPanes: Set<string> = new Set();

  // Message queue for input messages while disconnected
  private messageQueue: ClientMessage[] = [];

  // Connection timeout
  private connectTimer: ReturnType<typeof setTimeout> | null = null;

  constructor(url: string) {
    this.url = url;
  }

  connect(): void {
    this.shouldReconnect = true;
    this.doConnect();
  }

  disconnect(): void {
    this.shouldReconnect = false;
    this.clearTimers();
    this.subscribedPanes.clear();
    this.messageQueue = [];
    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }
  }

  send(msg: ClientMessage): void {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(msg));
    } else if (msg.type === "input") {
      // Queue input messages when disconnected
      this.messageQueue.push(msg);
    }
  }

  /** Subscribe to a specific pane's output. */
  subscribePane(paneId: string): void {
    this.subscribedPanes.add(paneId);
    this.send({ type: "subscribe_pane", pane_id: paneId });
  }

  /** Unsubscribe from a pane's output. */
  unsubscribePane(paneId: string): void {
    this.subscribedPanes.delete(paneId);
    this.send({ type: "unsubscribe_pane", pane_id: paneId });
  }

  /** Send input keys to a pane. */
  sendInput(paneId: string, keys: string): void {
    this.send({ type: "input", pane_id: paneId, keys });
  }

  /** Resize a pane. */
  resizePane(paneId: string, cols: number, rows: number): void {
    this.send({ type: "resize", pane_id: paneId, cols, rows });
  }

  onMessage(handler: MessageHandler): () => void {
    this.handlers.add(handler);
    return () => this.handlers.delete(handler);
  }

  get connected(): boolean {
    return this.ws?.readyState === WebSocket.OPEN;
  }

  private doConnect(): void {
    try {
      this.ws = new WebSocket(this.url);

      // Connection timeout: 5s
      this.connectTimer = setTimeout(() => {
        if (this.ws && this.ws.readyState !== WebSocket.OPEN) {
          this.ws.close();
        }
      }, 5000);

      this.ws.onopen = () => {
        if (this.connectTimer) {
          clearTimeout(this.connectTimer);
          this.connectTimer = null;
        }
        this.reconnectDelay = 1000;
        this.startHeartbeat();
        this.resubscribe();
        this.flushQueue();
      };

      this.ws.onmessage = (event) => {
        try {
          const msg: ServerMessage = JSON.parse(event.data);
          // Handle pong for heartbeat
          if (msg.type === "pong") {
            if (this.pongTimer) {
              clearTimeout(this.pongTimer);
              this.pongTimer = null;
            }
            return;
          }
          for (const handler of this.handlers) {
            handler(msg);
          }
        } catch {
          // ignore malformed messages
        }
      };

      this.ws.onclose = () => {
        this.ws = null;
        this.stopHeartbeat();
        if (this.connectTimer) {
          clearTimeout(this.connectTimer);
          this.connectTimer = null;
        }
        this.scheduleReconnect();
      };

      this.ws.onerror = () => {
        // onclose will fire after onerror
      };
    } catch {
      this.scheduleReconnect();
    }
  }

  private startHeartbeat(): void {
    this.stopHeartbeat();
    this.heartbeatTimer = setInterval(() => {
      if (this.ws?.readyState === WebSocket.OPEN) {
        this.ws.send(JSON.stringify({ type: "ping" }));
        // Expect pong within 5s
        this.pongTimer = setTimeout(() => {
          // No pong received — force close to trigger reconnect
          this.ws?.close();
        }, 5000);
      }
    }, 15000);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
    if (this.pongTimer) {
      clearTimeout(this.pongTimer);
      this.pongTimer = null;
    }
  }

  private resubscribe(): void {
    for (const paneId of this.subscribedPanes) {
      this.send({ type: "subscribe_pane", pane_id: paneId });
    }
  }

  private flushQueue(): void {
    const queued = this.messageQueue;
    this.messageQueue = [];
    for (const msg of queued) {
      this.send(msg);
    }
  }

  private clearTimers(): void {
    this.stopHeartbeat();
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    if (this.connectTimer) {
      clearTimeout(this.connectTimer);
      this.connectTimer = null;
    }
  }

  private scheduleReconnect(): void {
    if (!this.shouldReconnect) return;
    if (this.reconnectTimer) return;

    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.doConnect();
    }, this.reconnectDelay);

    // Exponential backoff with cap
    this.reconnectDelay = Math.min(
      this.reconnectDelay * 2,
      this.maxReconnectDelay
    );
  }
}
