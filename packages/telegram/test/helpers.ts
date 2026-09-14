// Shared plumbing for the suites. Not a *.test.ts file on purpose: the runner
// globs test/**/*.test.ts and must not pick this up as a suite.
//
// Every case runs against a local http server standing in for the Bot API —
// never api.telegram.org. A suite that could reach the real API would need a
// token, would be flaky, and could post into somebody's chat.
import http from 'node:http';
import type { AddressInfo } from 'node:net';
import { z } from 'zod';

const BodySchema = z.record(z.string(), z.unknown()).catch({});

/** One request the fake API received, in the order it arrived. */
export interface RecordedCall {
  /** The last path segment: `sendMessage`, `getUpdates`, … */
  method: string;
  body: Record<string, unknown>;
}

/**
 * What the fake API answers with. `'hang'` never answers at all — that is the
 * only way to exercise a client-side deadline honestly.
 */
export type Reply =
  | { ok: true; result: unknown }
  | { ok: false; error_code: number | string; description: string }
  | { raw: string }
  | 'hang';

export interface FakeApi {
  /** Pass this as `apiBase`; the client appends `/bot<token>/<method>`. */
  base: string;
  calls: RecordedCall[];
  /** The bodies of the calls to one method, in order. */
  bodiesOf(method: string): Record<string, unknown>[];
  close(): Promise<void>;
}

const OK_MESSAGE = { message_id: 1, chat: { id: 1 } };

/** A Bot API that answers `ok: true` with a plausible Message, unless told otherwise. */
export async function startApi(reply: (call: RecordedCall) => Reply = () => ({ ok: true, result: OK_MESSAGE })): Promise<FakeApi> {
  const calls: RecordedCall[] = [];
  const server = http.createServer((req, res) => {
    // An aborted request tears the socket down under us; that is the point of
    // the timeout case, not a failure of the server.
    req.on('error', () => undefined);
    res.on('error', () => undefined);
    const chunks: Buffer[] = [];
    req.on('data', (c: Buffer) => chunks.push(c));
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      const method = (req.url ?? '').split('/').pop() ?? '';
      const parsed: unknown = raw === '' ? {} : JSON.parse(raw);
      const call: RecordedCall = { method, body: BodySchema.parse(parsed) };
      calls.push(call);
      const answer = reply(call);
      if (answer === 'hang') return;
      const payload = 'raw' in answer ? answer.raw : JSON.stringify(answer);
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(payload);
    });
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address() as AddressInfo;
  return {
    base: `http://127.0.0.1:${port}`,
    calls,
    bodiesOf: (method: string) => calls.filter((c) => c.method === method).map((c) => c.body),
    close: () =>
      new Promise<void>((resolve) => {
        // A hung request still holds its socket; without this the close waits
        // for a response the case deliberately never sent.
        server.closeAllConnections();
        server.close(() => resolve());
      }),
  };
}

/** A `fetch` that never touches a socket: records what was asked, answers `ok: true`. */
export function stubFetch(result: unknown = OK_MESSAGE): { fetch: typeof fetch; methods: string[] } {
  const methods: string[] = [];
  return {
    methods,
    fetch: (input) => {
      methods.push(new URL(String(input)).pathname.split('/').pop() ?? '');
      return Promise.resolve(
        new Response(JSON.stringify({ ok: true, result }), { headers: { 'content-type': 'application/json' } })
      );
    },
  };
}

/** Lets everything already queued on the event loop run. */
export function settle(): Promise<void> {
  return new Promise<void>((resolve) => setImmediate(resolve));
}
