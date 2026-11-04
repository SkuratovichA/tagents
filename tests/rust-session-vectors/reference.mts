// The reference section of the session vectors: what `parseSessionRef` makes of the text of a reference, and whether the Rust code may answer a call that holds it.
//
// `parsed` is `JSON.stringify` of what node returned, or null when it returned null. `unusable` marks a reference the Rust verbs word as one they do not know (`badRef`): a reference node accepts but whose strings cannot be rebuilt byte for byte from what the Rust reader holds (a lone surrogate in a key, or in a string the schema keeps (it becomes an argument, an environment entry, a path, or the id a verb prints); a NUL; a `spec.env` entry that `spawn` refuses; an empty `bin`, or a relative `bin` with a slash in it) is one the binary cannot hold or act on. A reference node does not accept is `invalid` in both programs, and both say `no session matches`.
import { parseSessionRef } from '../../packages/core/src/session-ref.ts';

const SPEC = { kind: 'claude', cwd: '/work', skipPermissions: false };
const ref = (spec: Record<string, unknown> = SPEC, top: Record<string, unknown> = {}): string =>
  JSON.stringify({ id: 'r1', claudeSessionId: null, transcript: null, ...top, spec });

/** The reference with a text that holds the escape of a lone surrogate, which `JSON.stringify` of a JS string would write as the same six characters. */
const LONE = '\\ud83d';
const raw = (spec: string, top = ''): string => `{"id":"r1","claudeSessionId":null,"transcript":null${top},"spec":${spec}}`;

const TEXTS: string[] = [
  ref(),
  ref({ ...SPEC, skipPermissions: true }),
  ref({ ...SPEC, label: 'a', model: 'opus', effort: 'high', systemPromptFile: '/p', mcpConfig: '/m', disallowedTools: ['Bash', 'Edit'], env: { A: '1', B: '' }, bin: '/usr/bin/claude', logFile: '/l' }),
  ref({ ...SPEC, configDir: null }),
  ref({ ...SPEC, configDir: '/acct' }),
  ref({ ...SPEC, configDir: '' }),
  ref({ ...SPEC, label: '' }),
  ref({ ...SPEC, disallowedTools: [] }),
  ref({ ...SPEC, env: {} }),
  ref(SPEC, { claudeSessionId: 'abc', transcript: '/t.jsonl' }),
  ref(SPEC, { extra: 1 }),
  ref({ ...SPEC, extra: { a: 1 } }),
  `  ${ref()}\n`,
  `\n\t${ref()}`,
  // What the schema refuses.
  '',
  'null',
  '[]',
  '"text"',
  '{}',
  '{"id":"r1"}',
  raw('{}'),
  raw('null'),
  raw('[]'),
  ref({ ...SPEC, kind: 'other' }),
  ref({ ...SPEC, kind: undefined }),
  ref({ ...SPEC, cwd: 5 }),
  ref({ cwd: '/work', kind: 'claude' }),
  ref({ ...SPEC, skipPermissions: 'yes' }),
  ref({ ...SPEC, skipPermissions: 0 }),
  ref({ ...SPEC, skipPermissions: null }),
  ref({ ...SPEC, label: null }),
  ref({ ...SPEC, label: 5 }),
  ref({ ...SPEC, configDir: 5 }),
  ref({ ...SPEC, disallowedTools: 'Bash' }),
  ref({ ...SPEC, disallowedTools: ['Bash', 5] }),
  ref({ ...SPEC, env: [] }),
  ref({ ...SPEC, env: { A: 1 } }),
  ref({ ...SPEC, env: { A: null } }),
  ref({ ...SPEC, bin: 5 }),
  ref({ ...SPEC, logFile: null }),
  ref(SPEC, { id: 5 }),
  ref(SPEC, { id: null }),
  ref(SPEC, { claudeSessionId: 5 }),
  ref(SPEC, { claudeSessionId: undefined }),
  ref(SPEC, { transcript: undefined }),
  ref(SPEC, { transcript: 5 }),
  '{"id":"r1","claudeSessionId":null,"transcript":null,',
  `${ref()} ${ref()}`,
  `{"id":"a","id":"b","claudeSessionId":null,"transcript":null,"spec":${JSON.stringify(SPEC)}}`,
  `{"id":"r1","claudeSessionId":null,"transcript":null,"spec":${JSON.stringify(SPEC).slice(0, -1)},"cwd":"/other"}}`,
  // Keys that are not what they seem.
  raw(JSON.stringify(SPEC), ',"__proto__":{"a":1}'),
  raw(`{"kind":"claude","cwd":"/work","skipPermissions":false,"env":{"__proto__":"1","A":"b"}}`),
  raw(`{"kind":"claude","cwd":"/work","skipPermissions":false,"env":{"A":"b","A":"c"}}`),
  raw(`{"kind":"claude","cwd":"/work","skipPermissions":false,"env":{"2":"b","1":"c","A":"d"}}`),
  raw(`{"kind":"claude","cwd":"/work","skipPermissions":false,"env":{"__proto__":5,"A":"b"}}`),
  raw(`{"kind":"claude","cwd":"/work","skipPermissions":false,"env":{"A":5,"A":"x"}}`),
  raw(`{"kind":"claude","cwd":"/work","skipPermissions":false,"env":{"A":"x","A":5}}`),
  raw(`{"kind":"claude","cwd":"/work","skipPermissions":false,"__proto__":{"kind":"other"}}`),
  raw(`{"kind":"claude","cwd":"/work","skipPermissions":false,"constructor":1}`),
  // The classes of unusable reference.
  raw(`{"kind":"claude","cwd":"/work","skipPermissions":false,"label":"${LONE}"}`),
  raw(`{"kind":"claude","cwd":"/work${LONE}","skipPermissions":false}`),
  raw(`{"kind":"claude","cwd":"/work","skipPermissions":false,"disallowedTools":["a","${LONE}"]}`),
  raw(`{"kind":"claude","cwd":"/work","skipPermissions":false,"env":{"A":"${LONE}"}}`),
  raw(`{"kind":"claude","cwd":"/work","skipPermissions":false,"env":{"${LONE}":"a"}}`),
  raw(`{"kind":"claude","cwd":"/work","skipPermissions":false,"label":"\\ud83d\\ude00"}`),
  raw(`{"kind":"claude","cwd":"/work","skipPermissions":false,"label":"${LONE}\\ude00"}`),
  raw(`{"kind":"claude","cwd":"/work","skipPermissions":false,"extra":{"${LONE}":1}}`),
  raw(`{"kind":"claude","cwd":"/work","skipPermissions":false,"extra":"${LONE}"}`),
  raw(JSON.stringify(SPEC), `,"${LONE}":1`),
  raw(JSON.stringify(SPEC), `,"extra":"${LONE}"`),
  `{"id":"${LONE}","claudeSessionId":null,"transcript":null,"spec":${JSON.stringify(SPEC)}}`,
  `{"id":"r1","claudeSessionId":"${LONE}","transcript":null,"spec":${JSON.stringify(SPEC)}}`,
  `{"id":"r1","claudeSessionId":null,"transcript":"/t${LONE}","spec":${JSON.stringify(SPEC)}}`,
  ref(SPEC, { id: 'a\u0000b' }),
  ref(SPEC, { claudeSessionId: 'a\u0000b' }),
  ref(SPEC, { transcript: '/t\u0000.jsonl' }),
  ref({ ...SPEC, cwd: '/wo\u0000rk' }),
  ref({ ...SPEC, label: 'a\u0000b' }),
  ref({ ...SPEC, model: 'a\u0000b' }),
  ref({ ...SPEC, env: { 'A\u0000B': '1' } }),
  ref({ ...SPEC, env: { A: 'a\u0000b' } }),
  ref({ ...SPEC, env: { '': '1' } }),
  ref({ ...SPEC, env: { 'A=B': '1' } }),
  ref({ ...SPEC, env: { '=': '1' } }),
  ref({ ...SPEC, env: { A: 'a=b' } }),
  ref({ ...SPEC, bin: '' }),
  ref({ ...SPEC, bin: 'claude' }),
  ref({ ...SPEC, bin: './claude' }),
  ref({ ...SPEC, bin: 'bin/claude' }),
  ref({ ...SPEC, bin: '/abs/claude' }),
  ref({ ...SPEC, bin: '../claude' }),
  ref({ ...SPEC, bin: 'a\u0000b' }),
  ref({ ...SPEC, cwd: '' }),
  ref({ ...SPEC, cwd: 'relative' }),
  ref({ ...SPEC, label: 'é\u{1F600}' }),
];

/** A lone surrogate in a text that is not a JSON string literal is not one: only the escape is looked for. */
const hasLoneSurrogate = (text: string): boolean => !text.isWellFormed();

/** Whether any key of the parsed document, at any depth, holds a lone surrogate. */
function keyHasLoneSurrogate(value: unknown): boolean {
  if (Array.isArray(value)) return value.some(keyHasLoneSurrogate);
  if (value === null || typeof value !== 'object') return false;
  return Object.entries(value).some(([k, v]) => hasLoneSurrogate(k) || keyHasLoneSurrogate(v));
}

/** D2, for a reference that node accepted. `document` is what JSON.parse made of the text, for the keys the schema drops. */
function unusable(text: string, parsed: ReturnType<typeof parseSessionRef>): boolean {
  if (parsed === null) return false;
  const document: unknown = JSON.parse(text);
  if (keyHasLoneSurrogate(document)) return true;
  const { spec } = parsed;
  const kept = [parsed.id, parsed.claudeSessionId, parsed.transcript, spec.cwd, spec.bin, spec.label, spec.model, spec.effort, spec.systemPromptFile, spec.mcpConfig, spec.logFile, spec.configDir, ...(spec.disallowedTools ?? [])].filter((s): s is string => typeof s === 'string');
  const env = Object.entries(spec.env ?? {});
  if ([...kept, ...env.flat()].some((s) => hasLoneSurrogate(s) || s.includes('\u0000'))) return true;
  if (env.some(([name]) => name === '' || name.includes('='))) return true;
  if (spec.bin !== undefined && (spec.bin === '' || (!spec.bin.startsWith('/') && spec.bin.includes('/')))) return true;
  // A string of a field the schema drops is not read again, so it decides nothing.
  return false;
}

export function referenceVectors(): unknown {
  return {
    cases: TEXTS.map((text) => {
      const parsed = parseSessionRef(text);
      return { text, parsed: parsed === null ? null : JSON.stringify(parsed), unusable: unusable(text, parsed) };
    }),
  };
}
