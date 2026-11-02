// What the sections of the knowledge vectors share: the fixed clock, scratch directories, and an in-memory MCP client over the node server.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createServer } from '../../packages/knowledge/src/mcp/server.ts';

export const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
export const KNOWLEDGE_FIXTURES = path.join(REPO, 'packages/knowledge/test/fixtures');

/** Every date and every staleness in the vectors is read at this instant: 2026-10-31T12:00:00Z. */
export const NOW = Date.UTC(2026, 9, 31, 12, 0, 0);
export const clock = { now: (): number => NOW };

/** What a vector writes where a path would be, so a run in another scratch directory writes the same bytes. */
export const DIR = '<dir>';

/** A tiny deterministic generator, so a fuzz writes the same bytes at every run. */
export function lcg(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state / 0x1_0000_0000;
  };
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/** A value as JSON holds it: `undefined` is `null`, so a field that is absent is written. */
export function plain(value: unknown): unknown {
  if (value === undefined) return null;
  if (Array.isArray(value)) return value.map(plain);
  if (isRecord(value)) return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, plain(v)]));
  return value;
}

const scratchDirs: string[] = [];

/** An empty directory that `cleanup` removes. */
export function scratch(label: string): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), `rkv-${label}-`));
  scratchDirs.push(dir);
  return dir;
}

export function cleanup(): void {
  for (const dir of scratchDirs) fs.rmSync(dir, { recursive: true, force: true });
}

/** `text` with every occurrence of `dir` written as `<dir>`. */
export function relativize(text: string, dir: string): string {
  return text.split(dir).join(DIR);
}

export interface CorpusFile {
  readonly name: string;
  readonly text: string;
}

/** The `.md` files of a fixture folder, by name. */
export function fixtureFiles(folder: string): CorpusFile[] {
  const dir = path.join(KNOWLEDGE_FIXTURES, folder);
  return fs
    .readdirSync(dir)
    .filter((name) => name.endsWith('.md'))
    .sort()
    .map((name) => ({ name, text: fs.readFileSync(path.join(dir, name), 'utf8') }));
}

/** Write files into a folder, each with the modification time `mtimeSec` when one is given. */
export function writeFiles(dir: string, files: readonly CorpusFile[], mtimeSec?: number): void {
  fs.mkdirSync(dir, { recursive: true });
  for (const file of files) {
    const target = path.join(dir, file.name);
    fs.writeFileSync(target, file.text);
    if (mtimeSec !== undefined) fs.utimesSync(target, mtimeSec, mtimeSec);
  }
}

// ---- an MCP client without the SDK's client --------------------------------------------------

export interface JsonRpcMessage {
  readonly jsonrpc: '2.0';
  readonly id?: number;
  readonly method?: string;
  readonly params?: unknown;
  readonly result?: unknown;
  readonly error?: unknown;
}

interface End {
  onmessage?: (message: JsonRpcMessage) => void;
  onclose?: () => void;
  onerror?: (error: Error) => void;
  start(): Promise<void>;
  send(message: JsonRpcMessage): Promise<void>;
  close(): Promise<void>;
}

/** Two transports that hand each other's messages over: what `InMemoryTransport.createLinkedPair` does, without importing the SDK from outside its package. */
function linkedPair(): [End, End] {
  const hand = (to: () => End) => async (message: JsonRpcMessage): Promise<void> => {
    queueMicrotask(() => to().onmessage?.(message));
  };
  const a: End = { start: async () => undefined, send: hand(() => b), close: async () => b.onclose?.() };
  const b: End = { start: async () => undefined, send: hand(() => a), close: async () => a.onclose?.() };
  return [a, b];
}

export interface Connection {
  /** One request and its response, whatever the response holds; a request nothing answers within `silenceMs` gives null, and without `silenceMs` it fails. */
  request(method: string, params?: unknown, silenceMs?: number): Promise<JsonRpcMessage | null>;
  close(): Promise<void>;
}

/** The knowledge server of this checkout over `env`, shaken hands with as a client called `client`. */
export async function connect(env: NodeJS.ProcessEnv, client = 'knowledge-vectors'): Promise<Connection> {
  const server = createServer(env, clock);
  const [clientSide, serverSide] = linkedPair();
  const pending = new Map<number, (message: JsonRpcMessage) => void>();
  clientSide.onmessage = (message) => {
    if (message.id !== undefined) pending.get(message.id)?.(message);
  };
  await server.connect(serverSide);
  let next = 0;
  const request = (method: string, params?: unknown, silenceMs?: number): Promise<JsonRpcMessage | null> =>
    new Promise((resolve, reject) => {
      const id = ++next;
      const timer = setTimeout(
        () => (silenceMs === undefined ? reject(new Error(`no response to ${method} ${JSON.stringify(params)}`)) : resolve(null)),
        silenceMs ?? 10_000
      );
      pending.set(id, (message) => {
        clearTimeout(timer);
        resolve(message);
      });
      void clientSide.send({ jsonrpc: '2.0', id, method, ...(params === undefined ? {} : { params }) });
    });
  await request('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: client, version: '0.0.0' } });
  await clientSide.send({ jsonrpc: '2.0', method: 'notifications/initialized' });
  return {
    request,
    close: async () => {
      await server.close();
    },
  };
}

/** A tool result as the vectors keep it: the text and whether the call failed. */
export interface ToolOutcome {
  readonly isError: boolean;
  readonly text: string;
}

export function outcomeOf(response: JsonRpcMessage): ToolOutcome {
  const result = response.result;
  if (!isRecord(result)) throw new Error(`not a tool result: ${JSON.stringify(response)}`);
  const content = Array.isArray(result['content']) ? (result['content'] as unknown[]) : [];
  const text = content.map((c) => (isRecord(c) && typeof c['text'] === 'string' ? c['text'] : '')).join('');
  return { isError: result['isError'] === true, text };
}
