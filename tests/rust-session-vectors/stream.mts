// The stream section of the session vectors: what node's `StreamReader` does with the lines of a child's output, event by event and at the end.
//
// A case is the lines as the chunks they arrived in. Every answer is a text: an event is `JSON.stringify(event)`, which is the line `--events` writes, and the strings of the final state are `JSON.stringify` of them, so a lone surrogate stays an escape in this file.
import { StreamReader } from '../../packages/core/src/stream.ts';

const L = '\\ud83d';
const H = '\\ude00';
const result = (fields: string): string => `{"type":"result",${fields}}`;
const assistant = (...blocks: string[]): string => `{"type":"assistant","message":{"content":[${blocks.join(',')}]}}`;
const text = (t: string): string => `{"type":"text","text":${t}}`;
const tool = (name: string, input?: string): string => `{"type":"tool_use","name":"${name}"${input === undefined ? '' : `,"input":${input}`}}`;

const FULL = result('"is_error":false,"result":"done","session_id":"s1","total_cost_usd":0.0123,"duration_ms":4567,"num_turns":3');

/** Each entry is the whole output of a child, as a list of lines, to be joined with a newline (`final` is how the last one ends). */
const CASES: Array<{ readonly name: string; readonly lines: readonly string[]; readonly final?: boolean; readonly chunk?: number }> = [
  { name: 'empty', lines: [] },
  { name: 'result', lines: [FULL] },
  { name: 'result-key-order', lines: [result('"num_turns":1,"type":"result","session_id":"s","duration_ms":2,"result":"r","is_error":true,"total_cost_usd":3')] },
  { name: 'result-unknown-keys', lines: [result('"is_error":false,"zeta":1,"alpha":{"__proto__":{"a":1},"b":[1,2]},"result":"r","7":"seven","2":"two"')] },
  { name: 'result-top-level-proto', lines: [result('"is_error":false,"__proto__":{"x":1},"result":"r"')] },
  { name: 'result-minimal', lines: ['{"type":"result"}'] },
  { name: 'result-is-error-null', lines: [result('"is_error":null,"result":"r"')] },
  { name: 'result-is-error-string', lines: [result('"is_error":"no"')] },
  { name: 'result-result-number', lines: [result('"is_error":false,"result":5')] },
  { name: 'result-cost-infinity', lines: [result('"is_error":false,"total_cost_usd":1e999')] },
  { name: 'result-numbers', lines: [result('"is_error":false,"total_cost_usd":1e21,"duration_ms":-0,"num_turns":12345678901234567890')] },
  { name: 'result-small-numbers', lines: [result('"total_cost_usd":1e-7,"duration_ms":0.5,"num_turns":1E2')] },
  { name: 'result-session-id-empty', lines: [result('"is_error":false,"session_id":""')] },
  { name: 'result-session-id-number', lines: [result('"is_error":false,"session_id":5')] },
  { name: 'result-then-result', lines: [FULL, result('"is_error":true,"result":"second","session_id":"s2"')] },
  { name: 'result-then-text', lines: [FULL, assistant(text('"late"'))] },
  { name: 'result-lone-surrogate', lines: [result(`"is_error":false,"result":"${L}","session_id":"s"`)] },
  { name: 'plain-payload', lines: ['{"is_error":false,"result":"plain","session_id":"p1","total_cost_usd":0.5}'] },
  { name: 'plain-payload-null-is-error', lines: ['{"is_error":null}'] },
  { name: 'plain-payload-with-type', lines: ['{"type":"summary","is_error":false}'] },
  { name: 'plain-payload-empty-type', lines: ['{"type":"","is_error":true,"result":"r"}'] },
  { name: 'plain-object-no-is-error', lines: ['{"result":"r","session_id":"q"}'] },
  { name: 'assistant-text', lines: [assistant(text('"hello"'))] },
  { name: 'assistant-two-texts', lines: [assistant(text('"a"'), text('"b"')), assistant(text('" c "'))] },
  { name: 'assistant-empty-text', lines: [assistant(text('""'))] },
  { name: 'assistant-blank-text', lines: [assistant(text('"  "'))] },
  { name: 'assistant-tool', lines: [assistant(tool('Bash', '{"command":"ls"}'))] },
  { name: 'assistant-tool-no-input', lines: [assistant(tool('Read'))] },
  { name: 'assistant-tool-input-proto', lines: [assistant(tool('Bash', '{"__proto__":{"a":1},"b":2,"1":3}'))] },
  { name: 'assistant-tool-input-array', lines: [assistant(tool('Bash', '[1,2]'))] },
  { name: 'assistant-tool-input-null', lines: [assistant(tool('Bash', 'null'))] },
  { name: 'assistant-tool-no-name', lines: [assistant('{"type":"tool_use","input":{}}')] },
  { name: 'assistant-tool-input-numbers', lines: [assistant(tool('T', '{"n":1e21,"m":-0,"k":1e999,"s":"é"}'))] },
  { name: 'assistant-mixed', lines: [assistant(text('"one"'), tool('A', '{}'), '5', 'null', '{"type":"thinking","thinking":"x"}', tool('B', '{"x":1}'), text('"two"'))] },
  { name: 'assistant-content-not-array', lines: ['{"type":"assistant","message":{"content":"text"}}'] },
  { name: 'assistant-no-message', lines: ['{"type":"assistant"}'] },
  { name: 'assistant-empty-content', lines: [assistant()] },
  { name: 'assistant-lone-surrogate', lines: [assistant(text(`"${L}"`))] },
  { name: 'assistant-halves-join', lines: [assistant(text(`"a${L}"`)), assistant(text(`"${H}b"`))] },
  { name: 'assistant-halves-wrong-order', lines: [assistant(text(`"${H}"`)), assistant(text(`"${L}"`))] },
  { name: 'assistant-tool-lone-surrogate', lines: [assistant(tool('Bash', `{"command":"${L}","k":["${H}"]}`))] },
  { name: 'assistant-tool-name-lone-surrogate', lines: [assistant(tool(L))] },
  { name: 'user-event', lines: ['{"type":"user","message":{"content":[{"type":"tool_result","content":"x"}]}}'] },
  { name: 'system-event', lines: ['{"type":"system","subtype":"init","session_id":"init-1"}'] },
  { name: 'other-type-lone-surrogate', lines: [`{"type":"${L}"}`] },
  { name: 'assistant-tool-lone-key', lines: [assistant(tool('Bash', `{"${H}":"${L}","2":1,"a":{"${L}":[{"${H}":1}]},"${H}":2,"1":0,"${L}${H}":3,"__proto__":9}`))] },
  { name: 'result-lone-key', lines: [result(`"zeta":{"${H}":2},"${L}":1,"result":"r","is_error":false,"7":7,"${L}":8,"__proto__":9`)] },
  { name: 'plain-lone-key', lines: [`{"${L}":1,"is_error":false}`] },
  { name: 'block-lone-key', lines: [assistant(`{"${L}":1,"type":"tool_use","name":"N"}`, `{"${H}":2,"type":"text","text":"t"}`)] },
  { name: 'message-lone-key', lines: [`{"${L}":1,"type":"assistant","message":{"${H}":2,"content":[${text('"t"')}]}}`] },
  { name: 'other-lone-key', lines: [`{"${L}":1,"type":"x","session_id":"s"}`] },
  { name: 'envelope-session-id-only', lines: ['{"session_id":"only"}'] },
  { name: 'envelope-session-id-empty', lines: ['{"type":"system","session_id":""}'] },
  { name: 'envelope-session-id-later-empty', lines: ['{"type":"system","session_id":"first"}', '{"type":"system","session_id":""}'] },
  { name: 'envelope-session-id-changes', lines: ['{"type":"system","session_id":"a"}', '{"type":"system","session_id":"b"}'] },
  { name: 'envelope-type-number', lines: ['{"type":5,"session_id":"n"}'] },
  { name: 'envelope-session-id-number', lines: ['{"type":"system","session_id":5}'] },
  { name: 'session-id-then-result-without-one', lines: ['{"type":"system","session_id":"env"}', '{"type":"result","is_error":false}'] },
  { name: 'session-id-then-result-with-one', lines: ['{"type":"system","session_id":"env"}', FULL] },
  { name: 'noise', lines: ['', 'banner', '   ', '{broken', '[1,2]', '"string"', 'null', '{"type":"system"} trailing', '{"a":1}'] },
  { name: 'noise-around-result', lines: ['banner', FULL, 'noise'] },
  { name: 'spaces-around', lines: [`  \t${FULL}  `] },
  { name: 'crlf', lines: [`${assistant(text('"a"'))}\r`, `${FULL}\r`] },
  { name: 'bom-before-brace', lines: [`\ufeff${FULL}`] },
  { name: 'unicode-spaces', lines: [`\u00a0\u2003${FULL}\u3000`] },
  { name: 'line-separator-in-string', lines: [assistant(text('"a\u2028b\u2029c"'))] },
  { name: 'non-ascii', lines: [assistant(text('"caf\u00e9 \u4e2d \u{1F600}"'))] },
  { name: 'escapes-in-text', lines: [assistant(text('"q\\"b\\\\s\\/t\\tn\\nu\\u0001"'))] },
  { name: 'no-final-newline', lines: [assistant(text('"a"')), FULL], final: false },
  { name: 'no-final-newline-noise', lines: ['banner'], final: false },
  { name: 'final-newline-only', lines: [''], final: true },
  { name: 'chunked-by-three', lines: [assistant(text('"hello"')), FULL], chunk: 3 },
  { name: 'chunked-by-one', lines: [assistant(text('"caf\u00e9"'), tool('Bash', '{"a":1}')), FULL], chunk: 1 },
  { name: 'deep-input', lines: [assistant(tool('T', `${'['.repeat(200)}${']'.repeat(200)}`))] },
  { name: 'deep-input-object', lines: [assistant(tool('T', `{"a":${'{"a":'.repeat(150)}1${'}'.repeat(150)}}`))] },
];

function chunksOf(joined: string, size: number | undefined): string[] {
  if (size === undefined) return [joined];
  const units = [...joined];
  const out: string[] = [];
  for (let i = 0; i < units.length; i += size) out.push(units.slice(i, i + size).join(''));
  return out;
}

export function streamVectors(): unknown {
  return {
    cases: CASES.map((c) => {
      const events: string[] = [];
      const reader = new StreamReader((e) => events.push(JSON.stringify(e)));
      const joined = c.lines.join('\n') + (c.final === false || c.lines.length === 0 ? '' : '\n');
      for (const chunk of chunksOf(joined, c.chunk)) reader.push(chunk);
      reader.end();
      return {
        name: c.name,
        input: joined,
        chunk: c.chunk ?? null,
        events,
        payload: reader.payload === null ? null : JSON.stringify(reader.payload),
        sessionId: reader.sessionId,
        toolUses: reader.toolUses,
        text: JSON.stringify(reader.text),
        sawResult: reader.sawResult,
      };
    }),
  };
}
