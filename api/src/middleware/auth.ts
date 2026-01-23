import type { FastifyRequest, FastifyReply } from 'fastify';
import { config } from '../config.js';
import type { ApiError } from '../types/api.js';

export async function authMiddleware(
  request: FastifyRequest,
  reply: FastifyReply
): Promise<void> {
  const token = extractToken(request);

  if (!token) {
    const error: ApiError = {
      error: {
        code: 'AUTH_REQUIRED',
        message: 'Authorization token is required',
      },
    };
    return reply.status(401).send(error);
  }

  if (token !== config.auth.token) {
    const error: ApiError = {
      error: {
        code: 'AUTH_INVALID',
        message: 'Invalid authorization token',
      },
    };
    return reply.status(401).send(error);
  }
}

function extractToken(request: FastifyRequest): string | null {
  // Try Authorization header first
  const authHeader = request.headers.authorization;
  if (authHeader && authHeader.startsWith('Bearer ')) {
    return authHeader.slice(7);
  }

  // Fall back to query parameter (for WebSocket connections)
  const query = request.query as { token?: string };
  if (query.token) {
    return query.token;
  }

  return null;
}

export function extractTokenFromQuery(query: { token?: string }): string | null {
  return query.token || null;
}

export function validateToken(token: string | null): boolean {
  return token === config.auth.token;
}
