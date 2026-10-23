// The same knowledge, over MCP, for any client that speaks it.
//
// The framing is stdio, newline-delimited JSON-RPC. `runMcp` below is one process
// for one client: the client spawns it and owns its lifetime, which is what
// `claude mcp add tagents -- tagents-knowledge mcp` sets up and what makes the
// server usable from a headless `claude -p --strict-mcp-config` run with no
// port and no token. The plugin does not use it directly any more: daemon.ts
// serves the same `createServer` to many clients over a unix socket, and
// bin/knowledge-mcp falls back to `runMcp` whenever that cannot be had.
//
// NO TOOL WRITES A DOCUMENT, and that is a design decision, not an omission.
// The documents are a git repository the owner edits; a tool that could write
// them would put an agent's paraphrase into the source of truth without a
// diff, a review or a commit message. Reads are safe to hand out; writes go
// through git. The one thing a read tool leaves behind is an event in the usage
// store (usage.ts) for each document it returns: the owner's record of what is
// read, which is not a document and never changes an answer.
//
// stdout belongs to the JSON-RPC framing. Nothing in this file may print.
import fs from 'node:fs';
import type { DatabaseSync } from 'node:sqlite';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js';
import { z } from 'zod';
import { realClock, renderRecent, renderSearch } from '@tagents/core';
import { openDb, reindex } from '../db.ts';
import { resolveDb, resolveDir, resolveUsageDb } from '../paths.ts';
import { getDoc, getSection, listDocs, search, type Clock } from '../search.ts';
import { UsageStoreError, callerFrom, getEvent, hitEvents, parseSince, readUsageRows, recordReads, type UsageEvent, type UsageRow } from '../usage.ts';

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
  fn: (db: DatabaseSync, dir: string, indexFile: string) => T,
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
  const indexFile = resolveDb(null, env);
  const db = openDb(indexFile);
  try {
    reindex(db, dir.dir);
    return { ok: true, value: fn(db, dir.dir, indexFile) };
  } finally {
    db.close();
  }
}

const TYPE_HINT = 'case-insensitive, for example Runbook';

export function createServer(env: NodeJS.ProcessEnv = process.env, clock: Clock = realClock): McpServer {
  const server = new McpServer({ name: SERVER_NAME, version: SERVER_VERSION });

  /** Who is asking: the name the client gave in the handshake. */
  const caller = (): string | null => callerFrom(server.server.getClientVersion()?.name);
  /** Leave the events of a read in the usage store. Silent: a tool has nobody to tell, and a store that fails never changes an answer. */
  const record = (events: readonly UsageEvent[], indexFile: string): void =>
    recordReads(resolveUsageDb(null, indexFile, env), events, { now: clock });

  server.registerTool(
    'knowledge_search',
    {
      title: 'Search the knowledge base',
      description:
        'Full-text search over the owner\'s knowledge documents (Russian and English). Returns the matching sections as JSON: id, title, heading, score, snippet, path, type, description, status, stale. Documents with status deprecated come last. Read a whole section with knowledge_get.',
      inputSchema: {
        query: z.string().min(1).describe('words to look for; all of them must appear'),
        tag: z.string().optional().describe('only documents carrying this tag'),
        type: z.string().optional().describe(`only documents of this type (${TYPE_HINT})`),
        kind: z.string().optional().describe('deprecated alias of type'),
        limit: z.number().int().positive().max(50).optional().describe('how many sections (default 10)'),
      },
    },
    (args) => {
      const out = withDb((db, _dir, indexFile) => {
        const hits = search(db, [args.query], {
          ...(args.tag === undefined ? {} : { tag: args.tag }),
          ...(args.type === undefined ? {} : { type: args.type }),
          ...(args.kind === undefined ? {} : { kind: args.kind }),
          ...(args.limit === undefined ? {} : { limit: args.limit }),
          now: clock,
        });
        record(hitEvents(hits, caller()), indexFile);
        return hits;
      }, env);
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
      const out = withDb((db, _dir, indexFile): Answer<string> => {
        const doc = getDoc(db, args.id);
        if (!doc) return { ok: false, error: `no document with id "${args.id}"` };
        if (args.heading === undefined) {
          const text = readText(doc.path);
          record([getEvent(doc.id, '', caller())], indexFile);
          return { ok: true, value: text };
        }
        const section = getSection(db, args.id, args.heading);
        if (section === null)
          return {
            ok: false,
            error: `document "${args.id}" has no section "${args.heading}"; it has: ${doc.headings.join(', ') || '(none)'}`,
          };
        record([getEvent(doc.id, section.heading, caller())], indexFile);
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
      description:
        'Every document as JSON: id, title, type, description, tags, status, stale, updated, path, headings. Documents with status deprecated come last.',
      inputSchema: {
        type: z.string().optional().describe(`only this type (${TYPE_HINT})`),
        kind: z.string().optional().describe('deprecated alias of type'),
        tag: z.string().optional().describe('only documents carrying this tag'),
      },
    },
    (args) => {
      const out = withDb(
        (db) =>
          listDocs(db, {
            ...(args.type === undefined ? {} : { type: args.type }),
            ...(args.kind === undefined ? {} : { kind: args.kind }),
            ...(args.tag === undefined ? {} : { tag: args.tag }),
            now: clock,
          }),
        env
      );
      return out.ok ? ok(json(out.value)) : fail(out.error);
    }
  );

  server.registerTool(
    'knowledge_usage',
    {
      title: 'Which knowledge documents are read',
      description:
        'What the knowledge documents are used for, as JSON rows, the most read first: id, type, status, gets (times the document or one of its sections was read), hits (times a search returned it), days (distinct UTC dates with a get inside the window), last (UTC date of the newest get, null when never read). Unread documents are listed with zeros. With candidates, only the documents read often enough on enough days to be worth turning into a skill. Looking at the numbers is not a read.',
      inputSchema: {
        since: z.string().optional().describe('the window, a whole number of days and a d, for example 30d (default 30d)'),
        top: z.number().int().positive().optional().describe('how many rows (default 20)'),
        type: z.string().optional().describe(`only documents of this type (${TYPE_HINT})`),
        all: z.boolean().optional().describe('also list the ids that have events but are no longer in the folder'),
        candidates: z
          .boolean()
          .optional()
          .describe('only the documents that are not deprecated and were read at least min_gets times on at least min_days dates'),
        min_gets: z.number().int().positive().optional().describe('gets a candidate needs inside the window (default 5)'),
        min_days: z.number().int().positive().optional().describe('UTC dates a candidate needs a get on inside the window (default 3)'),
      },
    },
    (args) => {
      const sinceDays = args.since === undefined ? undefined : parseSince(args.since);
      if (sinceDays === null) return fail('since must be a positive whole number of days followed by d, such as 30d');
      const out = withDb((db, _dir, indexFile): Answer<UsageRow[]> => {
        try {
          const rows = readUsageRows(db, resolveUsageDb(null, indexFile, env), {
            now: clock,
            ...(sinceDays === undefined ? {} : { sinceDays }),
            ...(args.top === undefined ? {} : { top: args.top }),
            ...(args.type === undefined ? {} : { type: args.type }),
            ...(args.all === undefined ? {} : { all: args.all }),
            ...(args.candidates === undefined ? {} : { candidates: args.candidates }),
            ...(args.min_gets === undefined ? {} : { minGets: args.min_gets }),
            ...(args.min_days === undefined ? {} : { minDays: args.min_days }),
          });
          return { ok: true, value: rows };
        } catch (e) {
          if (!(e instanceof UsageStoreError)) throw e;
          return { ok: false, error: `the usage store ${e.file} cannot be read: ${e.reason}` };
        }
      }, env);
      if (!out.ok) return fail(out.error);
      return out.value.ok ? ok(json(out.value.value)) : fail(out.value.error);
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
