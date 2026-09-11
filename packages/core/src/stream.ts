// The `--output-format stream-json` reader: one JSON object per line, arriving
// in chunks that split anywhere.
//
// The one rule that matters here is what it does NOT do: it never accumulates
// stdout. With stream-json the child prints every tool RESULT too — megabytes
// of file contents and command output per turn — and turn.mjs kept all of it in
// a string just to re-parse it at the end. Feed chunks in, read the counters
// out; only the small parts (the result payload, assistant text) are kept.
import { z } from 'zod';
import type { StreamEvent } from './driver.ts';

/** The `result` event, which is exactly what `--output-format json` prints. */
export const PayloadSchema = z.object({
  is_error: z.boolean().optional(),
  result: z.string().optional(),
  session_id: z.string().optional(),
  total_cost_usd: z.number().optional(),
  duration_ms: z.number().optional(),
  num_turns: z.number().optional(),
});
export type ClaudePayload = z.infer<typeof PayloadSchema>;

const ResultEventSchema = PayloadSchema.extend({ type: z.literal('result') });
const AssistantEventSchema = z.object({
  type: z.literal('assistant'),
  message: z.object({ content: z.array(z.unknown()) }),
});
const ToolUseBlockSchema = z.object({
  type: z.literal('tool_use'),
  name: z.string(),
  input: z.record(z.string(), z.unknown()).optional(),
});
const TextBlockSchema = z.object({ type: z.literal('text'), text: z.string() });
const EnvelopeSchema = z.object({ type: z.string().optional(), session_id: z.string().optional() });

export class StreamReader {
  /** The result payload, once it has been seen. */
  payload: ClaudePayload | null = null;
  /** Set by ANY event that carries one — the id needed to resume this session. */
  sessionId: string | null = null;
  toolUses = 0;
  /** Assistant text only: what the model said, not what its tools returned. */
  text = '';
  /** Whether a `result` event has arrived. The turn is over from that moment. */
  sawResult = false;

  private pending = '';
  private readonly onEvent: ((e: StreamEvent) => void) | undefined;

  constructor(onEvent?: ((e: StreamEvent) => void) | undefined) {
    this.onEvent = onEvent;
  }

  push(chunk: string): void {
    this.pending += chunk;
    let nl = this.pending.indexOf('\n');
    while (nl >= 0) {
      this.line(this.pending.slice(0, nl));
      this.pending = this.pending.slice(nl + 1);
      nl = this.pending.indexOf('\n');
    }
  }

  /** The last line may have no trailing newline. */
  end(): void {
    const rest = this.pending;
    this.pending = '';
    if (rest) this.line(rest);
  }

  private emit(e: StreamEvent): void {
    try {
      this.onEvent?.(e);
    } catch {
      // A listener must not be able to fail the turn it is only watching.
    }
  }

  private line(raw: string): void {
    const line = raw.trim();
    if (!line.startsWith('{')) return; // a log banner or a half-written line
    let json: unknown;
    try {
      json = JSON.parse(line);
    } catch {
      return;
    }
    const env = EnvelopeSchema.safeParse(json);
    if (env.success && env.data.session_id) this.sessionId = env.data.session_id;

    const res = ResultEventSchema.safeParse(json);
    if (res.success) {
      this.payload = res.data;
      this.sawResult = true;
      this.emit({ kind: 'result', isError: res.data.is_error === true });
      return;
    }
    const asst = AssistantEventSchema.safeParse(json);
    if (asst.success) {
      for (const block of asst.data.message.content) {
        const tool = ToolUseBlockSchema.safeParse(block);
        if (tool.success) {
          this.toolUses += 1;
          this.emit({ kind: 'tool_use', name: tool.data.name, input: tool.data.input ?? {} });
          continue;
        }
        const text = TextBlockSchema.safeParse(block);
        if (text.success && text.data.text) {
          this.text += text.data.text;
          this.emit({ kind: 'text', text: text.data.text });
        }
      }
      return;
    }
    // `--output-format json` (no stream): one object, no `type`, with is_error.
    const plain = PayloadSchema.safeParse(json);
    if (plain.success && !env.data?.type && 'is_error' in (json as object)) {
      this.payload = plain.data;
      this.sawResult = true;
      this.emit({ kind: 'result', isError: plain.data.is_error === true });
      return;
    }
    if (env.success && env.data.type) this.emit({ kind: 'other', type: env.data.type });
  }
}
