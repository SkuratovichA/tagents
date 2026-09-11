// Runtime validation for the two shapes that cross a process boundary.
//
// `tagents-core session open` prints a SessionRef as JSON and `session prompt`
// takes one back, possibly hours later, possibly written by somebody else.
// driver.ts stays types-only (it is the vocabulary, it must not pull zod into
// a consumer that only wants the types); the checking lives here.
import { z } from 'zod';
import type { SessionRef, SessionSpec } from './driver.ts';

export const SessionSpecSchema = z.object({
  kind: z.literal('claude'),
  cwd: z.string(),
  label: z.string().optional(),
  configDir: z.string().nullable().optional(),
  model: z.string().optional(),
  effort: z.string().optional(),
  systemPromptFile: z.string().optional(),
  mcpConfig: z.string().optional(),
  disallowedTools: z.array(z.string()).optional(),
  skipPermissions: z.boolean(),
  env: z.record(z.string(), z.string()).optional(),
  bin: z.string().optional(),
  logFile: z.string().optional(),
});

export const SessionRefSchema = z.object({
  id: z.string(),
  claudeSessionId: z.string().nullable(),
  transcript: z.string().nullable(),
  spec: SessionSpecSchema,
});

/** Parse a SessionRef printed by `session open`. Null when it is not one. */
export function parseSessionRef(text: string): SessionRef | null {
  let json: unknown;
  try {
    json = JSON.parse(text);
  } catch {
    return null;
  }
  const parsed = SessionRefSchema.safeParse(json);
  return parsed.success ? toRef(parsed.data) : null;
}

type ParsedRef = z.infer<typeof SessionRefSchema>;
type ParsedSpec = z.infer<typeof SessionSpecSchema>;

/**
 * zod hands back a record with `key: undefined` for every absent optional, and
 * exactOptionalPropertyTypes means that is NOT the same as an absent key —
 * `configDir: undefined` and no `configDir` at all must stay distinguishable,
 * because for configDir they mean different accounts. Rebuild by presence.
 */
function toSpec(s: ParsedSpec): SessionSpec {
  return {
    kind: s.kind,
    cwd: s.cwd,
    skipPermissions: s.skipPermissions,
    ...(s.label === undefined ? {} : { label: s.label }),
    ...('configDir' in s && s.configDir !== undefined ? { configDir: s.configDir } : {}),
    ...(s.model === undefined ? {} : { model: s.model }),
    ...(s.effort === undefined ? {} : { effort: s.effort }),
    ...(s.systemPromptFile === undefined ? {} : { systemPromptFile: s.systemPromptFile }),
    ...(s.mcpConfig === undefined ? {} : { mcpConfig: s.mcpConfig }),
    ...(s.disallowedTools === undefined ? {} : { disallowedTools: s.disallowedTools }),
    ...(s.env === undefined ? {} : { env: s.env }),
    ...(s.bin === undefined ? {} : { bin: s.bin }),
    ...(s.logFile === undefined ? {} : { logFile: s.logFile }),
  };
}

function toRef(r: ParsedRef): SessionRef {
  return { id: r.id, claudeSessionId: r.claudeSessionId, transcript: r.transcript, spec: toSpec(r.spec) };
}
