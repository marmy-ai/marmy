import Fastify from 'fastify';
import websocket from '@fastify/websocket';
import cors from '@fastify/cors';
import { config } from './config.js';
import { authMiddleware } from './middleware/auth.js';
import { systemRoutes, projectRoutes, sessionRoutes } from './routes/index.js';
import { tmuxService } from './services/tmux.js';
import { logger } from './utils/logger.js';
import type { ApiError } from './types/api.js';

export async function createServer() {
  // Check tmux is installed
  const tmuxInstalled = await tmuxService.isInstalled();
  if (!tmuxInstalled) {
    throw new Error(
      'tmux is not installed. Please install tmux before running the server.'
    );
  }

  const fastify = Fastify({
    logger: {
      level: 'info',
      transport: {
        target: 'pino-pretty',
        options: {
          translateTime: 'HH:MM:ss Z',
          ignore: 'pid,hostname',
        },
      },
    },
  });

  // Register CORS
  await fastify.register(cors, {
    origin: true, // Allow all origins for local use
  });

  // Register WebSocket
  await fastify.register(websocket);

  // Register system routes (health check doesn't need auth)
  await fastify.register(async (instance) => {
    // Health endpoint - no auth
    instance.get('/api/health', async () => {
      return {
        status: 'ok',
        timestamp: new Date().toISOString(),
      };
    });
  });

  // Register authenticated routes
  await fastify.register(async (instance) => {
    // Add auth middleware to all routes in this scope
    instance.addHook('preHandler', authMiddleware);

    // Info endpoint
    instance.get('/api/info', async () => {
      const tmuxVersion = await tmuxService.getVersion();
      const { hostname } = await import('os');
      return {
        version: '1.0.0',
        hostname: hostname(),
        workspace: config.workspace.path,
        tmuxVersion,
      };
    });

    // Project routes
    await instance.register(projectRoutes);

    // Session routes
    await instance.register(sessionRoutes);
  });

  // Global error handler
  fastify.setErrorHandler((error, request, reply) => {
    logger.error('Request error', {
      error: error.message,
      stack: error.stack,
      url: request.url,
      method: request.method,
    });

    const apiError: ApiError = {
      error: {
        code: 'INTERNAL_ERROR',
        message: error.message || 'An unexpected error occurred',
      },
    };

    reply.status(500).send(apiError);
  });

  // Graceful shutdown
  const shutdown = async (signal: string) => {
    logger.info(`Received ${signal}, shutting down gracefully...`);
    await fastify.close();
    process.exit(0);
  };

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));

  return fastify;
}
