import { z } from 'zod';

// Error codes
export type ErrorCode =
  | 'AUTH_REQUIRED'
  | 'AUTH_INVALID'
  | 'PROJECT_NOT_FOUND'
  | 'SESSION_NOT_FOUND'
  | 'GIT_NOT_INITIALIZED'
  | 'TMUX_ERROR'
  | 'INTERNAL_ERROR';

export interface ApiError {
  error: {
    code: ErrorCode;
    message: string;
  };
}

// Request schemas
export const SubmitRequestSchema = z.object({
  text: z.string().min(1),
});

export type SubmitRequest = z.infer<typeof SubmitRequestSchema>;

// WebSocket message types
export interface WsContentMessage {
  type: 'content';
  data: {
    content: string;
    timestamp: string;
  };
}

export interface WsInputMessage {
  type: 'input';
  data: {
    text: string;
    submit?: boolean;
  };
}

export type WsServerMessage = WsContentMessage;
export type WsClientMessage = WsInputMessage;
