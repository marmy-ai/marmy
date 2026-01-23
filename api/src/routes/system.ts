import type { FastifyInstance } from 'fastify';
import { hostname } from 'os';
import { config } from '../config.js';
import { tmuxService } from '../services/tmux.js';

export async function systemRoutes(fastify: FastifyInstance): Promise<void> {
  // Health check - no auth required
  fastify.get('/api/health', async () => {
    return {
      status: 'ok',
      timestamp: new Date().toISOString(),
    };
  });

  // Server info - requires auth (registered separately with preHandler)
  fastify.get('/api/info', async () => {
    const tmuxVersion = await tmuxService.getVersion();

    return {
      version: '1.0.0',
      hostname: hostname(),
      workspace: config.workspace.path,
      tmuxVersion,
    };
  });
}
