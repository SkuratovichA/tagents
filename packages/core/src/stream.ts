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
export const PayloadSchema = z.looseObject({
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
/**
 * With `--replay-user-messages` the CLI echoes every stdin line it accepted as
 * a `user` event carrying `isReplay: true`, in the order written. Tool results
 * are `user` events too, without the flag.
 */
const ReplayEventSchema = z.object({ type: z.literal('user'), isReplay: z.literal(true) });

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
  private readonly onReplay: (() => void) | undefined;

  /**
   * `onReplay` hears every stdin line the CLI echoed back. It gets no id: the
   * reader cannot know which line it was, the writer does (the echo keeps the
   * write order), so the writer emits the `replay` event itself.
   */
  constructor(onEvent?: ((e: StreamEvent) => void) | undefined, onReplay?: (() => void) | undefined) {
    this.onEvent = onEvent;
    this.onReplay = onReplay;
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

    if (this.onReplay && ReplayEventSchema.safeParse(json).success) {
      try {
        this.onReplay();
      } catch {
        // Same rule as emit(): a listener must not fail the turn.
      }
      return;
    }

    const res = ResultEventSchema.safeParse(json);
    if (res.success) {
      this.payload = res.data;
      this.sawResult = true;
      this.emit({ kind: 'result', isError: res.data.is_error === true, payload: res.data });
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
      this.emit({ kind: 'result', isError: plain.data.is_error === true, payload: plain.data });
      return;
    }
    if (env.success && env.data.type) this.emit({ kind: 'other', type: env.data.type });
  }
}
