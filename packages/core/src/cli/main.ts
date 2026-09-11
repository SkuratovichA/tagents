#!/usr/bin/env node
// tagents-core — the CLI face of this package.
//
// Two kinds of output, and the difference is a contract:
//   * JSON verbs (session *) print EXACTLY ONE pretty-printed JSON document on
//     stdout and nothing else — no banner, no progress, no second document. The
//     one exception is `session prompt --events`, which streams one compact
//     JSON object per line and makes the TurnOutcome the last of them.
//   * text verbs (sessions recent|search|show) print what orchestrator's
//     sessions.mjs printed, byte for byte, because an agent reads that text out
//     of a shell and the orchestrator's fixtures pin it.
// Human-facing strings (usage, doctor, plugin) go through i18next; neither of
// the two contracts above does. `plugin list --json` is a JSON verb by that
// first rule; `plugin list` without it, and the other plugin verbs, are lines
// for a person — see cli/plugin.ts.
//
// A verb this file does not know is offered to the configured plugins before it
// is refused: `tagents-core telegram status` runs the `status` CliCommand of the
// plugin named `telegram` (cli/plugin-run.ts). The core verbs are matched FIRST
// and always win — what `session`, `sessions`, `plugin`, `doctor` and `help`
// mean must not depend on what somebody has installed.
//
// Exit codes: 0 ok · 1 error · 2 usage · 3 refused · 4 timeout.
import fs from 'node:fs';
import path from 'node:path';
import { parseArgs } from 'node:util';
import { pathToFileURL } from 'node:url';
import type { TFunction } from 'i18next';
import { ClaudeHeadlessDriver, DEFAULT_TIMEOUT_MS, TIMEOUT_WARN_BEFORE_MS } from '../claude-driver.ts';
import type { SessionRef, SessionSpec, SessionState, StreamEvent } from '../driver.ts';
import { readAgentState, stateDir } from '../agent-state.ts';
import { configFile } from '../host.ts';
import { createT } from '../i18n/index.ts';
import { isAlive } from '../pid.ts';
import { parseSessionRef } from '../session-ref.ts';
import { renderRecent, renderSearch, renderShow, SESSIONS_PROGRAM } from '../transcripts.ts';
import { formatAttemptError, type TurnOutcome } from '../turn-outcome.ts';
import { EXIT, json, type Io } from './exit.ts';
import { plugin } from './plugin.ts';
import { runPluginCommand } from './plugin-run.ts';

export { EXIT, type Io };

const STATES: readonly SessionState[] = ['new', 'working', 'blocked', 'done', 'gone'];

function isState(s: string): s is SessionState {
  return (STATES as readonly string[]).includes(s);
}

/** `session …` */
async function session(argv: string[], io: Io, t: TFunction): Promise<number> {
  const verb = argv[0];
  const rest = argv.slice(1);
  const driver = new ClaudeHeadlessDriver();

  if (verb === 'open') {
    const { values } = parseArgs({
      args: rest,
      options: {
        cwd: { type: 'string' },
        label: { type: 'string' },
        model: { type: 'string' },
        effort: { type: 'string' },
        resume: { type: 'string' },
        'system-prompt-file': { type: 'string' },
        'mcp-config': { type: 'string' },
        'config-dir': { type: 'string' },
        'no-config-dir': { type: 'boolean' },
        'skip-permissions': { type: 'boolean' },
      },
      strict: true,
      allowPositionals: false,
    });
    if (!values.cwd) {
      io.err(`${t('missingOption', { option: '--cwd' })}\n`);
      return EXIT.usage;
    }
    if (values['config-dir'] !== undefined && values['no-config-dir']) {
      io.err(`${t('unknownOption', { option: '--config-dir + --no-config-dir' })}\n`);
      return EXIT.usage;
    }
    const spec: SessionSpec = {
      kind: 'claude',
      cwd: path.resolve(values.cwd),
      skipPermissions: values['skip-permissions'] === true,
      ...(values.label === undefined ? {} : { label: values.label }),
      ...(values.model === undefined ? {} : { model: values.model }),
      ...(values.effort === undefined ? {} : { effort: values.effort }),
      ...(values['system-prompt-file'] === undefined ? {} : { systemPromptFile: values['system-prompt-file'] }),
      ...(values['mcp-config'] === undefined ? {} : { mcpConfig: values['mcp-config'] }),
      ...(values['no-config-dir'] ? { configDir: null } : {}),
      ...(values['config-dir'] === undefined ? {} : { configDir: values['config-dir'] }),
    };
    io.out(json(await driver.open(spec, values.resume ?? null)));
    return EXIT.ok;
  }

  if (verb === 'prompt') {
    const { values, positionals } = parseArgs({
      args: rest,
      options: {
        timeout: { type: 'string' },
        'warn-before': { type: 'string' },
        events: { type: 'boolean' },
      },
      strict: true,
      allowPositionals: true,
    });
    const [rawRef, text] = positionals;
    if (!rawRef || text === undefined) {
      io.err(`${t('missingOption', { option: '<ref> <text>' })}\n`);
      return EXIT.usage;
    }
    if (!text.trim()) {
      io.err(`${t('noPrompt')}\n`);
      return EXIT.usage;
    }
    const ref = await resolveRef(driver, rawRef);
    if (!ref) {
      io.err(`${t('badRef', { ref: rawRef })}\n`);
      return EXIT.error;
    }
    const streaming = values.events === true;
    const outcome = await driver.prompt(ref, text, {
      timeoutMs: num(values.timeout, DEFAULT_TIMEOUT_MS),
      warnBeforeMs: num(values['warn-before'], TIMEOUT_WARN_BEFORE_MS),
      ...(streaming ? { onEvent: (e: StreamEvent) => io.out(`${JSON.stringify(e)}\n`) } : {}),
    });
    io.out(streaming ? `${JSON.stringify(outcome)}\n` : json(outcome));
    const error = formatAttemptError(outcome);
    if (error) io.err(`${error}\n`);
    return exitFor(outcome);
  }

  if (verb === 'last') {
    const raw = rest[0];
    if (!raw) {
      io.err(`${t('missingOption', { option: '<ref>' })}\n`);
      return EXIT.usage;
    }
    const ref = await resolveRef(driver, raw);
    if (!ref) {
      io.err(`${t('badRef', { ref: raw })}\n`);
      return EXIT.error;
    }
    io.out(json(await driver.last(ref)));
    return EXIT.ok;
  }

  if (verb === 'list') {
    const { values } = parseArgs({
      args: rest,
      options: { label: { type: 'string' }, state: { type: 'string', multiple: true } },
      strict: true,
      allowPositionals: false,
    });
    const wanted = values.state ?? [];
    const bad = wanted.filter((s) => !isState(s));
    if (bad.length) {
      io.err(`${t('unknownOption', { option: `--state ${bad.join(',')}` })}\n`);
      return EXIT.usage;
    }
    io.out(
      json(
        await driver.list({
          ...(values.label === undefined ? {} : { label: values.label }),
          ...(wanted.length ? { state: wanted.filter(isState) } : {}),
        })
      )
    );
    return EXIT.ok;
  }

  if (verb === 'abort') {
    const raw = rest[0];
    if (!raw) {
      io.err(`${t('missingOption', { option: '<ref>' })}\n`);
      return EXIT.usage;
    }
    const ref = await resolveRef(driver, raw);
    if (!ref) {
      io.err(`${t('badRef', { ref: raw })}\n`);
      return EXIT.error;
    }
    await driver.abort(ref);
    // Across processes the only handle on a running turn is the pid the hook
    // records for a headless row; without one there is nothing here to stop.
    const row = readAgentState(stateDir()).find((r) => r.key === ref.id || r.sessionId === ref.claudeSessionId);
    const pid = row?.pid ?? null;
    if (pid === null || !isAlive(pid)) {
      io.err(`${t('nothingToAbort', { ref: raw })}\n`);
      return EXIT.refused;
    }
    try {
      process.kill(pid, 'SIGKILL');
    } catch {
      io.err(`${t('nothingToAbort', { ref: raw })}\n`);
      return EXIT.refused;
    }
    io.out(json({ aborted: true, id: ref.id, pid }));
    return EXIT.ok;
  }

  io.err(`${t('unknownCommand', { command: `session ${verb ?? ''}`.trim() })}\n${t('usage')}\n`);
  return EXIT.usage;
}

function num(raw: string | undefined, fallback: number): number {
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

function exitFor(o: TurnOutcome): number {
  if (o.kind === 'ok' || o.kind === 'killed-after-result') return EXIT.ok;
  return o.kind === 'timeout' ? EXIT.timeout : EXIT.error;
}

/** A ref is either the JSON `session open` printed, or an id the hook knows. */
async function resolveRef(driver: ClaudeHeadlessDriver, raw: string): Promise<SessionRef | null> {
  if (raw.trim().startsWith('{')) return parseSessionRef(raw);
  const known = await driver.list();
  return (
    known.find((r) => r.id === raw || r.claudeSessionId === raw) ??
    known.find((r) => r.claudeSessionId !== null && r.claudeSessionId.startsWith(raw)) ??
    null
  );
}

/**
 * `sessions …` — the text side. Every byte here, including the usage lines and
 * the name in them, is what sessions.mjs printed: the fixtures carried over
 * from the orchestrator are the oracle, and they name sessions.mjs.
 */
function sessions(argv: string[], io: Io): number {
  const [cmd, ...args] = argv;
  if (cmd === 'recent' || cmd === undefined) {
    io.out(renderRecent(Number(args[0]) || 15));
    return EXIT.ok;
  }
  if (cmd === 'search') {
    if (!args.length || !args.join(' ').trim()) {
      io.err(`usage: ${SESSIONS_PROGRAM} search <words…>\n`);
      return EXIT.error;
    }
    io.out(renderSearch(args));
    return EXIT.ok;
  }
  if (cmd === 'show') {
    const prefix = args[0];
    if (!prefix) {
      io.err(`usage: ${SESSIONS_PROGRAM} show <id-prefix>\n`);
      return EXIT.error;
    }
    const text = renderShow(prefix);
    if (text === null) {
      io.err(`no session starts with "${prefix}"\n`);
      return EXIT.error;
    }
    io.out(text);
    return EXIT.ok;
  }
  io.out(`usage: ${SESSIONS_PROGRAM} [recent [N] | search <words…> | show <id-prefix>]\n`);
  return EXIT.ok;
}

/** Is there a `claude` on PATH? Answered by looking, not by running it. */
function claudeOnPath(env: NodeJS.ProcessEnv = process.env): string | null {
  for (const dir of (env['PATH'] ?? '').split(path.delimiter).filter(Boolean)) {
    const candidate = path.join(dir, 'claude');
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      return candidate;
    } catch {
      continue;
    }
  }
  return null;
}

function doctor(io: Io, t: TFunction): number {
  const dir = stateDir();
  const file = configFile();
  const claude = claudeOnPath();
  io.out(`${t('doctorNode', { version: process.version, path: process.execPath })}\n`);
  io.out(`${t('doctorStateDir', { dir, count: readAgentState(dir).length })}\n`);
  io.out(`${t('doctorConfig', { file, status: fs.existsSync(file) ? t('present') : t('missing') })}\n`);
  io.out(`${t('doctorClaude', { status: claude ?? t('missing') })}\n`);
  return EXIT.ok;
}

export async function main(argv: string[], io: Io = stdio()): Promise<number> {
  const t = createT();
  const [verb, ...rest] = argv;
  try {
    if (verb === 'session') return await session(rest, io, t);
    if (verb === 'sessions') return sessions(rest, io);
    if (verb === 'plugin') return await plugin(rest, io, t);
    if (verb === 'doctor') return doctor(io, t);
    if (verb === undefined || verb === 'help' || verb === '--help' || verb === '-h') {
      io.out(`${t('usage')}\n`);
      return verb === undefined ? EXIT.usage : EXIT.ok;
    }
    // Every core verb is already answered above, so a word that got this far is
    // free to be a plugin's — and only then does the config get read at all.
    const fromPlugin = await runPluginCommand(verb, rest, io, t);
    if (fromPlugin !== null) return fromPlugin;
    io.err(`${t('unknownCommand', { command: verb })}\n${t('usage')}\n`);
    return EXIT.usage;
  } catch (e) {
    // parseArgs throws for an unknown flag: that is a usage error, not a crash.
    const err = e as NodeJS.ErrnoException;
    const usage = typeof err.code === 'string' && err.code.startsWith('ERR_PARSE_ARGS');
    io.err(`${err.message}\n`);
    return usage ? EXIT.usage : EXIT.error;
  }
}

/**
 * `tagents-core sessions recent | head` closes the pipe while we are still
 * writing, and an unhandled EPIPE turns that into a stack trace on a command
 * that did nothing wrong. Reading half the output is a legitimate thing to do
 * to a CLI, so the writes are best-effort.
 */
function stdio(): Io {
  const ignore = (): void => undefined;
  process.stdout.on('error', ignore);
  process.stderr.on('error', ignore);
  const write = (stream: NodeJS.WriteStream, text: string): void => {
    try {
      stream.write(text);
    } catch {
      // The reader is gone; there is nobody left to tell.
    }
  };
  return {
    out: (s) => write(process.stdout, s),
    err: (s) => write(process.stderr, s),
  };
}

// Run only as a program, never on import: a test imports main() directly.
// realpath first — installed as a bin, argv[1] is a symlink into .bin while
// import.meta.url is already the file it points at.
const invokedAs = process.argv[1] ? pathToFileURL(fs.realpathSync(process.argv[1])).href : '';
if (invokedAs === import.meta.url) {
  process.exitCode = await main(process.argv.slice(2));
}
