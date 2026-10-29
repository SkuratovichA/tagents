/** One thing done to the dashboard at `at` milliseconds into a recording: keys typed into it, or a line sent to a fake agent. */
export type Step = { readonly at: number } & (
  | { readonly keys: readonly string[] }
  | { readonly ctl: readonly [window: string, command: string] }
)

export interface SceneDef {
  readonly id: string
  readonly steps: readonly Step[]
  /** Milliseconds the recording runs. */
  readonly until: number
}

const down = (at: number, count: number, every = 350): Step[] =>
  Array.from({ length: count }, (_, step) => ({ at: at + step * every, keys: ['Down'] }))

export const SCENES: readonly SceneDef[] = [
  {
    // the list as it is, an agent that stops to ask, and the cursor going to it
    id: 'hero',
    until: 11_000,
    steps: [
      { at: 1_500, ctl: ['api', "permit 'pnpm test --filter api'"] },
      ...down(3_500, 8),
      { at: 7_000, keys: ['Enter'] },
    ],
  },
  {
    // every key, in a popup over the list, left open so the last frame is the list of keys
    id: 'keys',
    until: 4_500,
    steps: [
      { at: 1_000, keys: ['?'] },
      { at: 2_500, keys: ['Down', 'Down', 'Down'] },
    ],
  },
  {
    // a new agent in the project under the cursor
    id: 'new-chat',
    until: 9_000,
    steps: [...down(1_000, 5), { at: 3_500, keys: ['C-n'] }],
  },
  {
    // closed sessions, and one of them resumed
    id: 'closed',
    until: 9_000,
    steps: [
      { at: 1_000, keys: ['C-y'] },
      { at: 3_000, keys: ['Down'] },
      { at: 5_000, keys: ['Enter'] },
    ],
  },
]
