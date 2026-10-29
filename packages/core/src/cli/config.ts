// `tagents-core config …` — the config file itself.
//
//   config convert [FILE] [--write] [--all]
//
// `convert` turns the YAML config into TOML. By default it only prints, and
// changes nothing anywhere; --write creates the .toml beside the YAML and
// refuses to touch a file that is already there; neither ever deletes or edits
// the YAML. --all adds the per-host overlays (config.<host>.yaml), and a write
// is all or nothing: one refusal, one failed conversion, and no file appears.
// What tagents reads out of the result is checked against the YAML before a
// byte is offered (config-convert.ts).
import fs from 'node:fs';
import path from 'node:path';
import { parseArgs } from 'node:util';
import { convertYamlConfig, tomlTwin, yamlOverlays } from '../config-convert.ts';
import { configFormat } from '../config-file.ts';
import { configDir } from '../host.ts';
import type { CoreT } from '../i18n/index.ts';
import { EXIT, type Io } from './exit.ts';
import { CONFIG_CONVERT } from './spec.ts';

/** The YAML file tagents is reading: $TA_CONFIG when it names one (the dashboard's own override), else config.yaml in the config dir. */
function defaultSource(env: NodeJS.ProcessEnv): string {
  const named = env['TA_CONFIG'];
  return named && named.trim() ? named : path.join(configDir(env), 'config.yaml');
}

/** Remove `file`, saying whether it is gone. A failing removal must not replace the error that made it necessary. */
function removed(file: string): boolean {
  try {
    fs.rmSync(file, { force: true });
    return true;
  } catch {
    return false;
  }
}

function convert(argv: string[], io: Io, t: CoreT, env: NodeJS.ProcessEnv, cwd: string): number {
  const { values, positionals } = parseArgs({
    args: argv,
    options: CONFIG_CONVERT.options,
    strict: true,
    allowPositionals: true,
  });
  if (positionals.length > 1) {
    io.err(`${t('unknownOption', { option: positionals[1] ?? '' })}\n${t('usage')}\n`);
    return EXIT.usage;
  }

  const given = positionals[0];
  const base = path.resolve(cwd, given ?? defaultSource(env));
  if (configFormat(base) === 'toml') {
    io.err(`${t('configNotYaml', { file: base })}\n`);
    return EXIT.usage;
  }
  if (!fs.existsSync(base)) {
    io.err(`${given === undefined ? t('configNoSource', { dir: path.dirname(base) }) : t('configNoFile', { file: base })}\n`);
    return EXIT.error;
  }

  const sources = values.all === true ? [base, ...yamlOverlays(base)] : [base];
  const write = values.write === true;

  // Every refusal comes before the first write.
  if (write) {
    const taken = sources.map(tomlTwin).find((target) => fs.existsSync(target));
    if (taken !== undefined) {
      io.err(`${t('configTargetExists', { file: taken })}\n`);
      return EXIT.refused;
    }
  }
  const converted: Array<{ source: string; target: string; toml: string; mode: number }> = [];
  for (const source of sources) {
    const result = convertYamlConfig(source);
    if (!result.ok) {
      io.err(`${result.problem}\n`);
      return EXIT.refused;
    }
    converted.push({ source, target: tomlTwin(source), toml: result.toml, mode: fs.statSync(source).mode & 0o777 });
  }

  if (!write) {
    for (const [i, c] of converted.entries()) {
      if (sources.length > 1) io.out(`${i === 0 ? '' : '\n'}# ==== ${c.target} ====\n`);
      io.out(c.toml);
    }
    io.err(`${t('configCommentsLost')}\n`);
    return EXIT.ok;
  }

  const written: string[] = [];
  for (const c of converted) {
    try {
      fs.writeFileSync(c.target, c.toml, { flag: 'wx', mode: c.mode });
      written.push(c.target);
    } catch (err) {
      // `wx` has created the target by the time most failures happen, so it goes too; on EEXIST the file is somebody else's and stays.
      if (!(err instanceof Error && (err as NodeJS.ErrnoException).code === 'EEXIST')) written.push(c.target);
      const stuck = written.filter((file) => !removed(file));
      io.err(`${t('configWriteFailed', { file: c.target, error: err instanceof Error ? err.message : String(err) })}\n`);
      if (stuck.length > 0) io.err(`${t('configNotRemoved', { files: stuck.join(', ') })}\n`);
      return EXIT.error;
    }
  }
  for (const c of converted) io.out(`${t('configWrote', { target: c.target, source: c.source })}\n`);
  io.err(`${t('configCommentsLost')}\n`);
  return EXIT.ok;
}

/** The `config` verb, dispatched. Throws nothing main.ts does not already catch. */
export function config(argv: string[], io: Io, t: CoreT, env: NodeJS.ProcessEnv = process.env, cwd: string = process.cwd()): number {
  const [verb, ...rest] = argv;
  if (verb === 'convert') return convert(rest, io, t, env, cwd);
  io.err(`${t('unknownCommand', { command: `config ${verb ?? ''}`.trim() })}\n${t('usage')}\n`);
  return EXIT.usage;
}
