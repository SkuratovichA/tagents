// Records the demos of the page from the real dashboard:
//
//   pnpm capture [scene ...]
//
// For each scene it brings up docs/demo's fake world (fake agents, a fake `claude`, nothing of the machine it runs on) on a tmux server of its own, attaches to it from a second scratch tmux server so that one pane holds the whole composed screen, types the scene's keys and records the screen every 100 ms with `tmux capture-pane -e -p`. The result is src/demos/data/<id>.ts. It needs bash, tmux 3.4+ and fzf 0.63+, like docs/demo/record.sh.
import { execFileSync, spawn } from 'node:child_process'
import { mkdirSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { parseScreen } from './ansi.ts'
import { encode, type Shot } from './frames.ts'
import { SCENES, type SceneDef, type Step } from './scenes.ts'

const repo = resolve(import.meta.dirname, '..', '..')
const out = resolve(import.meta.dirname, '..', 'src', 'demos', 'data')
// A unix socket path is limited to ~100 bytes: the root stays short.
const root = process.env.TAGENTS_SITE_CAPTURE_ROOT ?? '/tmp/tagents-site-cap'
const COLS = 160
const ROWS = 28
const TICK = 100
const SETTLE = 6_000

const sleep = (ms: number) => new Promise<void>((done) => setTimeout(done, ms))

/** The environment docs/demo/env.sh makes: HOME, tmux and tagents state all moved under the root. */
function demoEnv(): NodeJS.ProcessEnv {
  const raw = execFileSync('bash', ['-c', '. "$REPO_DEMO/env.sh" && env -0'], {
    env: {
      PATH: process.env.PATH ?? '',
      REPO_DEMO: resolve(repo, 'docs', 'demo'),
      DEMO_ROOT: root,
      TA_WIDTH: '52',
    },
  }).toString()
  return Object.fromEntries(
    raw
      .split('\0')
      .filter(Boolean)
      .map((pair) => [pair.slice(0, pair.indexOf('=')), pair.slice(pair.indexOf('=') + 1)]),
  )
}

const env = demoEnv()
const world = (...args: string[]) =>
  execFileSync('bash', [resolve(repo, 'docs', 'demo', 'world.sh'), ...args], { env, stdio: 'pipe' })
const outerSocket = `${env.DEMO_ROOT ?? root}/outer.sock`
const outer = (...args: string[]) =>
  execFileSync('tmux', ['-S', outerSocket, ...args], { env, stdio: 'pipe' }).toString()

function startOuter(): void {
  const conf = `${env.DEMO_ROOT ?? root}/outer.conf`
  writeFileSync(
    conf,
    'set -g status off\nset -g default-terminal tmux-256color\nset -g escape-time 0\n',
  )
  execFileSync(
    'tmux',
    [
      '-S',
      outerSocket,
      '-f',
      conf,
      'new-session',
      '-d',
      '-s',
      'outer',
      '-x',
      String(COLS),
      '-y',
      String(ROWS), // tmux sets TMUX in the panes it starts, and a nested attach refuses to run with it
      'env -u TMUX -u TMUX_PANE tmux attach -t storefront',
    ],
    { env, stdio: 'pipe' },
  )
}

function stopAll(): void {
  try {
    outer('kill-server')
  } catch {
    // no server of ours is running
  }
  try {
    world('down')
  } catch {
    // no world is up
  }
}

const screen = () => outer('capture-pane', '-e', '-p', '-t', 'outer')

function perform(step: Step): void {
  if ('keys' in step) outer('send-keys', '-t', 'outer', ...step.keys)
  else world('ctl', ...step.ctl)
}

async function record(scene: SceneDef): Promise<void> {
  stopAll()
  mkdirSync(env.DEMO_ROOT ?? root, { recursive: true })
  world('up')
  startOuter()
  // brings the cockpit up as soon as the outer server has attached, like the tapes do
  await new Promise<void>((done, fail) => {
    const child = spawn(
      'bash',
      [resolve(repo, 'docs', 'demo', 'world.sh'), 'dash-when-attached', '0.6'],
      { env, stdio: 'ignore' },
    )
    child.on('exit', (code) => {
      if (code === 0) done()
      else fail(new Error(`dash-when-attached exited ${code}`))
    })
  })
  await sleep(SETTLE)
  if (!screen().includes('agents>')) throw new Error(`${scene.id}: the dashboard did not come up`)

  const shots: Shot[] = []
  const steps = [...scene.steps].sort((a, b) => a.at - b.at)
  let next = 0
  const started = Date.now()
  let previous = ''
  for (let now = 0; now <= scene.until; now = Date.now() - started) {
    for (let due = steps[next]; due !== undefined && due.at <= now; due = steps[next]) {
      perform(due)
      next++
    }
    const captured = screen()
    if (captured !== previous) shots.push({ t: now, lines: parseScreen(captured) })
    previous = captured
    await sleep(TICK)
  }
  const data = encode(scene.id, COLS, shots)
  const name = scene.id.replace(/-(\w)/g, (_, letter: string) => letter.toUpperCase())
  mkdirSync(out, { recursive: true })
  writeFileSync(
    resolve(out, `${scene.id}.ts`),
    `// Recorded by capture/run.ts from the real dashboard. Do not edit by hand: run \`pnpm capture ${scene.id}\`.\nimport type { Scene } from '../../lib/screen.ts'\n\nexport const ${name}: Scene = ${JSON.stringify(data)}\n`,
  )
  console.log(
    `${scene.id}: ${data.frames.length} frames, ${data.styles.length} styles, ${shots.at(-1)?.t ?? 0} ms`,
  )
}

const wanted = process.argv.slice(2)
try {
  for (const scene of SCENES)
    if (wanted.length === 0 || wanted.includes(scene.id)) await record(scene)
} finally {
  stopAll()
}
