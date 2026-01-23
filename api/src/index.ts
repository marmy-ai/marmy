import { createServer } from './server.js';
import { config } from './config.js';
import { logger } from './utils/logger.js';

async function main() {
  try {
    const server = await createServer();

    await server.listen({
      host: config.server.host,
      port: config.server.port,
    });

    logger.info(`Marmy API server started`, {
      host: config.server.host,
      port: config.server.port,
      workspace: config.workspace.path,
    });
  } catch (error) {
    console.error('Failed to start server:', error);
    process.exit(1);
  }
}

main();
