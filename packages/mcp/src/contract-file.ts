// contract.json, and any file written in the shape of one program's entry in it, read back into CLI contracts. The generator wrote the file from the specs; this is the one place the server reads it, and it stops with the reason when the file is not what the generator writes.
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
const ContractFile = z.object({ cli: z.record(z.string(), Body) });

const reason = (error: z.ZodError): string => error.issues.map((i) => `${i.path.join('.') || '(top level)'}: ${i.message}`).join('; ');

/** One program's spec with its name, as the bash script's spec file holds it. */
export function parseCliContract(value: unknown): CliContract {
  const parsed = Spec.safeParse(value);
  if (!parsed.success) throw new Error(`not a CLI spec: ${reason(parsed.error)}`);
  return parsed.data;
}

/** The `cli` section of contract.json's text, one contract per program in the order the file lists them. */
export function cliContractsOf(text: string): readonly CliContract[] {
  let json: unknown;
  try {
    json = JSON.parse(text);
  } catch (error) {
    throw new Error(`the contract is not JSON: ${error instanceof Error ? error.message : String(error)}`);
  }
  const parsed = ContractFile.safeParse(json);
  if (!parsed.success) throw new Error(`the contract has no usable cli section: ${reason(parsed.error)}`);
  return Object.entries(parsed.data.cli).map(([program, body]) => ({ program, ...body }));
}
