// The options of `<configDir>/plugins/notify.yaml`.
//
// Every key is optional and the schema fills in the rest, so a file that says
// only `click: goto` is a complete configuration. Objects are strict at every
// level: a misspelt `skip_visble` that is silently ignored leaves the user
// wondering why nothing changed, while one that is a problem names the key.
import { z } from 'zod';

const DURATION = /^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$/;

/**
 * A duration in milliseconds: `90` and `'90'` are seconds, `'45s'`, `'50m'`,
 * `'2h'` and `'1h30m'` are units, in that order. Integers only, because
 * `1.5h` is a thing people write when they mean `90m`, and the schema would
 * rather say no than round it.
 */
export function parseDuration(v: string | number): number | null {
  if (typeof v === 'number') return Number.isSafeInteger(v) && v >= 0 ? v * 1000 : null;
  if (/^\d+$/.test(v)) return parseDuration(Number(v));
  const m = v === '' ? null : DURATION.exec(v);
  if (m === null) return null;
  const seconds = Number(m[1] ?? 0) * 3600 + Number(m[2] ?? 0) * 60 + Number(m[3] ?? 0);
  return Number.isSafeInteger(seconds) ? seconds * 1000 : null;
}

// A transform that reports through the context, so the problem lands on the
// key that holds the bad duration and not on the file as a whole.
const Duration = z.union([z.string(), z.number()]).transform((v, ctx) => {
  const ms = parseDuration(v);
  if (ms === null) {
    ctx.issues.push({
      code: 'custom',
      message: `not a duration: ${JSON.stringify(v)} (use 90, 45s, 50m, 2h or 1h30m)`,
      input: v,
    });
    return z.NEVER;
  }
  return ms;
});

// `.prefault({})` and not `.default({})`: zod 4's `default` returns its value
// as it is, without parsing it, so a missing `events.question` would come back
// as `{}` with none of its own defaults. `prefault` feeds the value through the
// schema, which fills them in.
function toggles(enabled: boolean, skipVisible: boolean) {
  return {
    enabled: z.boolean().default(enabled),
    skip_visible: z.boolean().default(skipVisible),
  };
}

const simple = (enabled: boolean, skipVisible: boolean) =>
  z.strictObject(toggles(enabled, skipVisible)).prefault({});

const CacheExpiring = z
  .strictObject({
    ...toggles(true, false),
    after: Duration.prefault('50m'),
    ttl: Duration.prefault('60m'),
  })
  .refine((o) => o.after < o.ttl, {
    message: 'after must be below ttl: a notice about a cache that already expired helps nobody',
    path: ['after'],
  })
  .prefault({});

export const NotifyOptionsSchema = z.strictObject({
  backend: z.enum(['auto', 'macos', 'log', 'none']).default('auto'),
  click: z.enum(['dock', 'goto', 'focus']).default('dock'),
  sessions: z.strictObject({ headless: z.boolean().default(false) }).prefault({}),
  events: z
    .strictObject({
      question: simple(true, true),
      permission: simple(true, true),
      turn_done: simple(true, true),
      cache_expiring: CacheExpiring,
      subagent_done: simple(false, true),
      session_end: simple(false, true),
    })
    .prefault({}),
});

export type NotifyOptions = z.output<typeof NotifyOptionsSchema>;
