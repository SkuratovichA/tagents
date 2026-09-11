// A plugin the way a real one is written: one default-exported definition, no
// side effects on import. Plain .mjs so the host imports it exactly as it would
// import a built plugin out of somebody's dist/.
//
// Its name ('fixture') deliberately differs from its package name, which is the
// key `plugin add` writes ('fixture-plugin'): both spellings have to reach the
// same commands. Everything below `echo` exists so one suite can drive the CLI
// through every answer running a plugin command can give — coercion, a failing
// schema, an exit code that is not 0, a throw, positionals.
import { z } from 'zod';

export default {
  name: 'fixture',
  apiVersion: 1,
  locales: { en: { fixture: { hello: 'hello from the fixture' } } },
  commands: [
    {
      name: 'echo',
      describe: 'print what it was given',
      args: z.object({ text: z.string() }),
      run: async (a, ctx) => {
        ctx.log(a.text);
        return 0;
      },
    },
    {
      name: 'greet',
      describe: 'greet somebody a number of times',
      // --times arrives as the string argv had; coercion is the schema's job.
      args: z.object({ name: z.string(), times: z.coerce.number().int().min(1).default(1) }),
      run: async (a, ctx) => {
        for (let i = 0; i < a.times; i += 1) ctx.log('hello', a.name);
        return 0;
      },
    },
    {
      name: 'exits',
      describe: 'exit with the code it was given',
      args: z.object({ code: z.coerce.number().int() }),
      run: async (a) => a.code,
    },
    {
      name: 'boom',
      describe: 'throw, to show what a failing command looks like',
      args: z.object({}),
      run: async () => {
        throw new Error('the fixture exploded');
      },
    },
    {
      name: 'join',
      describe: 'join its positional arguments',
      args: z.object({ _: z.array(z.string()).default([]) }),
      run: async (a, ctx) => {
        ctx.log(a._.join('+'));
        return 0;
      },
    },
  ],
  services: [
    {
      name: 'ticker',
      start: async () => ({ drain: async () => undefined, stop: () => undefined }),
    },
  ],
  mcpTools: [
    {
      name: 'sessions_recent',
      describe: 'the latest sessions',
      input: z.object({ limit: z.number().optional() }),
      run: async () => ({ sessions: [] }),
    },
  ],
};
