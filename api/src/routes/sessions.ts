import type { FastifyInstance } from 'fastify';
import type { SocketStream } from '@fastify/websocket';
import { createHash } from 'crypto';
import { sessionService } from '../services/session.js';
import { tmuxService } from '../services/tmux.js';
import { projectService } from '../services/project.js';
import { validateToken } from '../middleware/auth.js';
import { logger } from '../utils/logger.js';
import { SubmitRequestSchema } from '../types/api.js';
import type { ApiError, WsServerMessage, WsClientMessage } from '../types/api.js';

interface SessionParams {
  id: string;
}

export async function sessionRoutes(fastify: FastifyInstance): Promise<void> {
  // List all sessions
  fastify.get('/api/sessions', async () => {
    const sessions = await sessionService.listSessions();
    return { sessions };
  });

  // Get single session
  fastify.get<{ Params: SessionParams }>(
    '/api/sessions/:id',
    async (request, reply) => {
      const { id } = request.params;
      const session = await sessionService.getSession(id);

      if (!session) {
        const error: ApiError = {
          error: {
            code: 'SESSION_NOT_FOUND',
            message: `Session '${id}' not found`,
          },
        };
        return reply.status(404).send(error);
      }

      return session;
    }
  );

  // Get session content
  fastify.get<{ Params: SessionParams }>(
    '/api/sessions/:id/content',
    async (request, reply) => {
      const { id } = request.params;

      const exists = await tmuxService.sessionExists(id);
      if (!exists) {
        const error: ApiError = {
          error: {
            code: 'SESSION_NOT_FOUND',
            message: `Session '${id}' not found`,
          },
        };
        return reply.status(404).send(error);
      }

      try {
        const content = await sessionService.getSessionContent(id);
        return content;
      } catch (err) {
        const error: ApiError = {
          error: {
            code: 'TMUX_ERROR',
            message: `Failed to capture session content: ${err instanceof Error ? err.message : 'Unknown error'}`,
          },
        };
        return reply.status(500).send(error);
      }
    }
  );

  // Submit to session (creates session if needed)
  fastify.post<{ Params: SessionParams }>(
    '/api/sessions/:id/submit',
    async (request, reply) => {
      const { id } = request.params;

      // Validate request body
      const parseResult = SubmitRequestSchema.safeParse(request.body);
      if (!parseResult.success) {
        const error: ApiError = {
          error: {
            code: 'INTERNAL_ERROR',
            message: 'Invalid request body: text is required',
          },
        };
        return reply.status(400).send(error);
      }

      const { text } = parseResult.data;

      // Check if project exists and has git
      const project = await projectService.getProject(id);
      if (!project) {
        const error: ApiError = {
          error: {
            code: 'PROJECT_NOT_FOUND',
            message: `Project '${id}' not found`,
          },
        };
        return reply.status(404).send(error);
      }

      if (!project.hasGit) {
        const error: ApiError = {
          error: {
            code: 'GIT_NOT_INITIALIZED',
            message: `Project '${id}' has no git initialized. Git is required for Claude Code sessions.`,
          },
        };
        return reply.status(400).send(error);
      }

      try {
        await sessionService.submitToSession(id, text);
        return reply.status(200).send();
      } catch (err) {
        const error: ApiError = {
          error: {
            code: 'TMUX_ERROR',
            message: `Failed to submit to session: ${err instanceof Error ? err.message : 'Unknown error'}`,
          },
        };
        return reply.status(500).send(error);
      }
    }
  );

  // Kill session
  fastify.delete<{ Params: SessionParams }>(
    '/api/sessions/:id',
    async (request, reply) => {
      const { id } = request.params;

      try {
        await sessionService.killSession(id);
        return reply.status(204).send();
      } catch (err) {
        if (err instanceof Error && err.message.includes('not found')) {
          const error: ApiError = {
            error: {
              code: 'SESSION_NOT_FOUND',
              message: `Session '${id}' not found`,
            },
          };
          return reply.status(404).send(error);
        }

        const error: ApiError = {
          error: {
            code: 'TMUX_ERROR',
            message: `Failed to kill session: ${err instanceof Error ? err.message : 'Unknown error'}`,
          },
        };
        return reply.status(500).send(error);
      }
    }
  );

  // WebSocket streaming
  fastify.get<{ Params: SessionParams; Querystring: { token?: string } }>(
    '/api/sessions/:id/stream',
    { websocket: true },
    async (connection: SocketStream, request) => {
      const { id } = request.params;
      const { token } = request.query;
      const ws = connection.socket;

      // Validate token
      if (!validateToken(token || null)) {
        logger.warn('WebSocket connection rejected: invalid token');
        ws.close(1008, 'Invalid token');
        return;
      }

      logger.info(`WebSocket connected for session: ${id}`);

      let lastContentHash = '';
      let pollInterval: ReturnType<typeof setInterval> | null = null;

      const pollContent = async () => {
        try {
          const exists = await tmuxService.sessionExists(id);
          if (!exists) {
            return;
          }

          const sessionContent = await sessionService.getSessionContent(id);
          const contentHash = createHash('md5')
            .update(sessionContent.content)
            .digest('hex');

          // Only send if content changed
          if (contentHash !== lastContentHash) {
            lastContentHash = contentHash;
            const message: WsServerMessage = {
              type: 'content',
              data: {
                content: sessionContent.content,
                timestamp: sessionContent.timestamp,
              },
            };
            ws.send(JSON.stringify(message));
          }
        } catch (err) {
          logger.error('Error polling session content', { error: err, sessionId: id });
        }
      };

      // Start polling
      pollInterval = setInterval(pollContent, 500);

      // Initial content send
      pollContent();

      // Handle incoming messages
      ws.on('message', async (data: Buffer | ArrayBuffer | Buffer[]) => {
        try {
          const message = JSON.parse(data.toString()) as WsClientMessage;

          if (message.type === 'input' && message.data.text) {
            const submit = message.data.submit !== false;
            await tmuxService.sendText(id, message.data.text, submit);
          }
        } catch (err) {
          logger.error('Error processing WebSocket message', { error: err });
        }
      });

      // Cleanup on close
      ws.on('close', () => {
        logger.info(`WebSocket disconnected for session: ${id}`);
        if (pollInterval) {
          clearInterval(pollInterval);
        }
      });

      ws.on('error', (err: Error) => {
        logger.error('WebSocket error', { error: err, sessionId: id });
        if (pollInterval) {
          clearInterval(pollInterval);
        }
      });
    }
  );
}
