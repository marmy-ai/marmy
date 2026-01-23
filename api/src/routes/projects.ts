import type { FastifyInstance } from 'fastify';
import { projectService } from '../services/project.js';
import type { ApiError } from '../types/api.js';

interface ProjectParams {
  name: string;
}

export async function projectRoutes(fastify: FastifyInstance): Promise<void> {
  // List all projects
  fastify.get('/api/projects', async () => {
    const projects = await projectService.listProjects();
    return { projects };
  });

  // Get single project
  fastify.get<{ Params: ProjectParams }>(
    '/api/projects/:name',
    async (request, reply) => {
      const { name } = request.params;
      const project = await projectService.getProject(name);

      if (!project) {
        const error: ApiError = {
          error: {
            code: 'PROJECT_NOT_FOUND',
            message: `Project '${name}' not found`,
          },
        };
        return reply.status(404).send(error);
      }

      return project;
    }
  );
}
