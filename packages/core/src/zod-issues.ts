import type { z } from 'zod';

/** One line per issue, `path: message`, the way a compiler lists them. */
export function issueLines(error: z.ZodError): string[] {
  return error.issues.map((issue) => {
    const where = issue.path.map(String).join('.');
    return where ? `${where}: ${issue.message}` : issue.message;
  });
}
