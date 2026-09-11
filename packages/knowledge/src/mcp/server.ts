// The same knowledge, over MCP, for any client that speaks it.
//
// stdio only: the client spawns this process and owns its lifetime, which is
// what `claude mcp add tagents -- tagents-knowledge mcp` sets up and what makes
// the server usable from a headless `claude -p --strict-mcp-config` run with no
// port, no token and no daemon to leave running.
//
// THERE ARE NO WRITE TOOLS, and that is a design decision, not an omission.
// The documents are a git repository the owner edits; a tool that could write
// them would put an agent's paraphrase into the source of truth without a
// diff, a review or a commit message. Reads are safe to hand out; writes go
// through git.
//
// stdout belongs to the JSON-RPC framing. Nothing in this file may print.
import fs from 'node:fs';
import type { DatabaseSync } from 'node:sqlite';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js';
import { z } from 'zod';
import { renderRecent, renderSearch } from '@tagents/core';
import { KINDS } from '../doc.ts';
import { openDb, reindex } from '../db.ts';
import { resolveDb, resolveDir } from '../paths.ts';
import { getDoc, getSection, listDocs, search } from '../search.ts';

export const SERVER_NAME = 'tagents-knowledge';
export const SERVER_VERSION = '0.1.0';
export const MAX_SESSIONS = 50;

/** Tool text is machine-facing, so it is English everywhere — like JSON output. */
const ok = (text: string): CallToolResult => ({ content: [{ type: 'text', text }] });
const fail = (text: string): CallToolResult => ({ content: [{ type: 'text', text }], isError: true });

const json = (value: unknown): string => JSON.stringify(value, null, 2);

/**
 * Open the index, bring it in line with the folder, run one query, close.
 *
 * Per call rather than per process: the documents are edited by a human in an
 * editor while this server is connected, and an agent reading last week's copy
 * of a runbook is exactly the failure this package exists to end. An
 * incremental reindex over a folder this size is a handful of stat() calls.
 */
type Answer<T> = { readonly ok: true; readonly value: T } | { readonly ok: false; readonly error: string };

function withDb<T>(
  fn: (db: DatabaseSync, dir: string) => T,
  env: NodeJS.ProcessEnv = process.env
): Answer<T> {
  const dir = resolveDir(null, env);
  if (!dir.ok)
    return {
      ok: false,
      error:
        dir.reason === 'unset'
          ? `no knowledge directory: set TAGENTS_KNOWLEDGE_DIR or knowledge.dir in ${dir.config}`
          : `knowledge directory ${dir.dir} does not exist`,
    };
  const db = openDb(resolveDb(null, env));
  try {
    reindex(db, dir.dir);
    return { ok: true, value: fn(db, dir.dir) };
  } finally {
    db.close();
  }
}

const KIND_VALUES = KINDS.join(' | ');

export function createServer(env: NodeJS.ProcessEnv = process.env): McpServer {
  const server = new McpServer({ name: SERVER_NAME, version: SERVER_VERSION });

  server.registerTool(
    'knowledge_search',
    {
      title: 'Search the knowledge base',
      description:
        'Full-text search over the owner\'s knowledge documents (Russian and English). Returns the matching sections as JSON: id, title, heading, score, snippet, path. Read a whole section with knowledge_get.',
      inputSchema: {
        query: z.string().min(1).describe('words to look for; all of them must appear'),
        tag: z.string().optional().describe('only documents carrying this tag'),
        kind: z.string().optional().describe(`only documents of this kind (${KIND_VALUES})`),
        limit: z.number().int().positive().max(50).optional().describe('how many sections (default 10)'),
      },
    },
    (args) => {
      const out = withDb(
        (db) =>
          search(db, [args.query], {
            ...(args.tag === undefined ? {} : { tag: args.tag }),
            ...(args.kind === undefined ? {} : { kind: args.kind }),
            ...(args.limit === undefined ? {} : { limit: args.limit }),
          }),
        env
      );
      if (!out.ok) return fail(out.error);
      return out.value.length ? ok(json(out.value)) : ok(`nothing matches "${args.query}"`);
    }
  );

  server.registerTool(
    'knowledge_get',
    {
      title: 'Read one knowledge document',
      description:
        'The markdown of one document by id, or of a single "## " section when heading is given.',
      inputSchema: {
        id: z.string().min(1).describe('document id, the filename stem'),
        heading: z
          .string()
          .optional()
          .describe('a "## " heading inside that document; omit for the whole document'),
      },
    },
    (args) => {
      const out = withDb((db): Answer<string> => {
        const doc = getDoc(db, args.id);
        if (!doc) return { ok: false, error: `no document with id "${args.id}"` };
        if (args.heading === undefined) return { ok: true, value: readText(doc.path) };
        const section = getSection(db, args.id, args.heading);
        if (section === null)
          return {
            ok: false,
            error: `document "${args.id}" has no section "${args.heading}"; it has: ${doc.headings.join(', ') || '(none)'}`,
          };
        return { ok: true, value: `## ${section.heading}\n\n${section.body}\n` };
      }, env);
      if (!out.ok) return fail(out.error);
      return out.value.ok ? ok(out.value.value) : fail(out.value.error);
    }
  );

  server.registerTool(
    'knowledge_list',
    {
      title: 'List the knowledge documents',
      description: 'Every document as JSON: id, title, kind, tags, updated, path, headings.',
      inputSchema: {
        kind: z.string().optional().describe(`only this kind (${KIND_VALUES})`),
        tag: z.string().optional().describe('only documents carrying this tag'),
      },
    },
    (args) => {
      const out = withDb(
        (db) =>
          listDocs(db, {
            ...(args.kind === undefined ? {} : { kind: args.kind }),
            ...(args.tag === undefined ? {} : { tag: args.tag }),
          }),
        env
      );
      return out.ok ? ok(json(out.value)) : fail(out.error);
    }
  );

  server.registerTool(
    'sessions_recent',
    {
      title: 'Recent Claude sessions on this machine',
      description:
        'The latest sessions across every Claude account on this machine, newest first — the same text the sessions CLI prints.',
      inputSchema: {
        limit: z.number().int().positive().max(MAX_SESSIONS).optional().describe('how many (default 15)'),
      },
    },
    (args) => ok(renderRecent(args.limit ?? 15))
  );

  server.registerTool(
    'sessions_search',
    {
      title: 'Find a Claude session',
      description:
        'Sessions whose project path or opening prompt contains every one of these words — the same text the sessions CLI prints.',
      inputSchema: {
        words: z.string().min(1).describe('words that must all appear'),
      },
    },
    (args) => ok(renderSearch(args.words.split(/\s+/).filter(Boolean)))
  );

  return server;
}

/** The document as it is on disk — frontmatter included, which is context too. */
function readText(file: string): string {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch {
    return `document file ${file} is gone; run the index`;
  }
}

/** Serve on stdio until the client closes the pipe. */
export async function runMcp(env: NodeJS.ProcessEnv = process.env): Promise<void> {
  const server = createServer(env);
  const transport = new StdioServerTransport();
  await server.connect(transport);
  await new Promise<void>((resolve) => {
    transport.onclose = resolve;
  });
}
