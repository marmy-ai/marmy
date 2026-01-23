import { exec as execCallback } from 'child_process';
import { promisify } from 'util';

const execPromise = promisify(execCallback);

export interface ExecResult {
  stdout: string;
  stderr: string;
}

export interface ExecOptions {
  timeout?: number;
  cwd?: string;
}

export async function exec(
  command: string,
  options: ExecOptions = {}
): Promise<ExecResult> {
  const { timeout = 30000, cwd } = options;

  try {
    const result = await execPromise(command, {
      timeout,
      cwd,
      maxBuffer: 10 * 1024 * 1024, // 10MB buffer
    });

    return {
      stdout: result.stdout,
      stderr: result.stderr,
    };
  } catch (error: unknown) {
    if (error instanceof Error && 'stderr' in error) {
      const execError = error as Error & { stderr?: string; stdout?: string };
      throw new Error(
        `Command failed: ${command}\n${execError.stderr || execError.message}`
      );
    }
    throw error;
  }
}
