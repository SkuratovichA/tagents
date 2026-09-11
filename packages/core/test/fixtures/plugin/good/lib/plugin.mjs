// A plugin the way a real one is written: one default-exported definition, no
// side effects on import. Plain .mjs so the host imports it exactly as it would
// import a built plugin out of somebody's dist/.
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
