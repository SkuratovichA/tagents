// One program's spec in the shape of its entry in contract.json (the bash script's spec file is written that way), read into a CLI contract; it stops with the reason when the file is not that shape.
import type { CliContract } from '@tagents/core';
import { z } from 'zod';

const Option = z.object({ type: z.enum(['string', 'boolean']), multiple: z.boolean().exactOptional() });

const Effect = z.enum(['read', 'write', 'spawn', 'destructive', 'serve']);

// A contract written by a newer generator can hold an effect this server has not heard of, and unknown keys: neither may take every tool away. The effect is dropped, which makes the verb unclassified (the cautious hints), and unknown keys are stripped by the object.
const Command = z
  .object({
    path: z.array(z.string()),
    positionals: z.array(z.string()),
    options: z.record(z.string(), Option),
    required: z.array(z.string()),
    summary: z.string(),
    effect: z.string().exactOptional(),
    requires: z.literal('tmux').exactOptional(),
    tool: z.literal(false).exactOptional(),
    toolDefaults: z.record(z.string(), z.boolean()).exactOptional(),
  })
  .transform(({ effect, ...command }) => {
    const known = Effect.safeParse(effect);
    return known.success ? { ...command, effect: known.data } : command;
  });

const Body = z.object({ exit: z.record(z.string(), z.number()), commands: z.array(Command) });
const Spec = Body.extend({ program: z.string() });

const reason = (error: z.ZodError): string => error.issues.map((i) => `${i.path.join('.') || '(top level)'}: ${i.message}`).join('; ');

/** One program's spec with its name, as the bash script's spec file holds it. */
export function parseCliContract(value: unknown): CliContract {
  const parsed = Spec.safeParse(value);
  if (!parsed.success) throw new Error(`not a CLI spec: ${reason(parsed.error)}`);
  return parsed.data;
}
