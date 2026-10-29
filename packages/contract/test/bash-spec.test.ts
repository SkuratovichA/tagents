// node --test bash-spec.test.ts
//
// tagents.cli.json is the structured spec of the verbs of the bash script `tagents`, which has no argument parser a generator could read. This file pins it to the one place the script describes itself, `tagents --help`: every verb in the file is in the help with the same positionals, and every verb in the help is either in the file or in the list below with the reason a client is not offered it. A verb added to the help and to neither fails here.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { parseCliContract } from '../../mcp/src/contract-file.ts';
import { parsePositional } from '../../mcp/src/tools.ts';
import { scriptHelps } from '../src/sources.ts';
import { REPO_ROOT } from '../src/tree.ts';

/** The verbs of `tagents --help` that are not tools, each with why. */
const NOT_TOOLS: Readonly<Record<string, string>> = {
  '--timeline': 'draws bars for a terminal',
  '--list': 'fzf rows with colour codes and hidden key columns; `tagents-core session list` and tmux answer the same question as data',
  '--flat': 'the same rows as --list',
  '--counts': 'the tmux status bar line, in tmux format codes',
  '--preview': 'the dashboard\'s preview pane',
  '--preview-popup': 'the dashboard\'s preview popup',
  '--sync-names': 'a pass the refresher already runs',
  '--keys': 'the dashboard\'s key table, for its help window',
  '--closed-rows': 'rows the dashboard\'s closed-session picker is built from',
  '--resurrect-save': 'reboot recovery, written for tmux-resurrect\'s hooks',
  '--resurrect-rows': 'reboot recovery',
  '--resurrect': 'reboot recovery',
  '--hidden-cols': 'the dashboard\'s column state',
  '--col-rows': 'the dashboard\'s column picker',
  '--toggle-col': 'the dashboard\'s column picker',
  '--header': 'the dashboard\'s key header',
  '--ensure-dash': 'takes the client to the dashboard, which is the person\'s screen',
  '--viewport': 'the dashboard\'s own pane, an error anywhere else',
  '--follow': 'run by tmux\'s own hooks',
  '--agent-cmd': 'a debugging aid for the launch path, which --new already runs',
  update: 'moves the installed copy of tagents itself',
  '<verb>': 'forwards to tagents-core, whose verbs are tools already',
};

interface HelpVerb {
  readonly verb: string;
  /** the usage tokens after the verb, as the help prints them: `DIR`, `[PROFILE]` */
  readonly tokens: readonly string[];
  /** the flags the usage line prints in brackets, without the dashes: `detach` for `[--detach]` */
  readonly flags: readonly string[];
}

const FLAG = /^\[--([a-z][a-z-]*)\]$/;

/** The `  tagents <verb> …` lines of the help; the line that is the bare command (the dashboard) is not a verb. */
function helpVerbs(help: string): HelpVerb[] {
  const verbs: HelpVerb[] = [];
  for (const line of help.split('\n')) {
    if (!line.startsWith('  tagents ')) continue;
    const usage = (line.trim().split(/ {2,}/)[0] ?? '').split(' ').slice(1);
    const [verb, ...all] = usage;
    if (verb === undefined || !/^(--|update$|<verb>$)/.test(verb)) continue;
    const rest = all.filter((token) => !FLAG.test(token));
    const flags = all.flatMap((token) => FLAG.exec(token)?.[1] ?? []);
    verbs.push({ verb, flags, tokens: rest.filter((token, i) => rest.slice(0, i + 1).every((t) => /^\[?[A-Z][A-Z-]*\]?$/.test(t))) });
  }
  return verbs;
}

const spec = parseCliContract(JSON.parse(fs.readFileSync(path.join(REPO_ROOT, 'tagents.cli.json'), 'utf8')));
const help = (await scriptHelps(REPO_ROOT)).find((s) => s.name === 'tagents')?.help ?? '';
const inHelp = helpVerbs(help);

test('the help is read: it names the verbs the script has', () => {
  assert.ok(inHelp.length > 20, `read ${inHelp.length} verbs`);
  assert.ok(inHelp.some((v) => v.verb === '--new'));
});

test('every verb in the spec is in the help, with the positionals the help prints', () => {
  for (const command of spec.commands) {
    const verb = command.path.join(' ');
    const printed = inHelp.find((v) => v.verb === verb);
    assert.ok(printed !== undefined, `${verb} is not in tagents --help`);
    const theirs = printed.tokens.map((t) => (t.startsWith('[') ? t : `<${t}>`)).map(parsePositional);
    assert.deepEqual(command.positionals.map(parsePositional), theirs, verb);
  }
});

test('every verb in the spec has the options the help prints as flags, and the help prints no flag the spec lacks', () => {
  for (const command of spec.commands) {
    const verb = command.path.join(' ');
    assert.deepEqual(Object.keys(command.options).sort(), [...(inHelp.find((v) => v.verb === verb)?.flags ?? [])].sort(), `${verb}: options in the spec and flags in tagents --help`);
  }
});

test('every verb in the help is in the spec or in the list of what is not a tool, and the list holds nothing that is gone', () => {
  const specified = new Set(spec.commands.map((c) => c.path.join(' ')));
  const printed = new Set(inHelp.map((v) => v.verb));
  const loose = [...printed].filter((verb) => !specified.has(verb) && !(verb in NOT_TOOLS));
  assert.deepEqual(loose, [], 'name each in tagents.cli.json, or in NOT_TOOLS with the reason');
  assert.deepEqual(Object.keys(NOT_TOOLS).filter((verb) => !printed.has(verb)), [], 'in NOT_TOOLS but not in the help');
  assert.deepEqual([...specified].filter((verb) => verb in NOT_TOOLS), [], 'both a tool and not a tool');
  for (const [verb, reason] of Object.entries(NOT_TOOLS)) assert.notEqual(reason.trim(), '', verb);
});

test('a verb that starts a window or a session needs the caller\'s own tmux server', () => {
  const spawns = spec.commands.filter((c) => c.effect === 'spawn');
  assert.ok(spawns.length > 0);
  for (const command of spawns) assert.equal(command.requires, 'tmux', command.path.join(' '));
});
