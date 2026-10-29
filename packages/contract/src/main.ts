// node packages/contract/src/main.ts [--check]
//
// Without --check: writes contract.json, the references and plugin.json's version and digest, deletes stray reference files, prints what changed. With --check: writes nothing and exits 1 naming every stale path.
import { parseArgs } from 'node:util';
import { silenceSqliteWarning } from '../../knowledge/src/db.ts';
import { createT } from './i18n/index.ts';
import { REPO_ROOT, applyPlan, changeLines, noticeLines, planTree, staleLines } from './tree.ts';

async function main(argv: readonly string[]): Promise<number> {
  // Collecting the MCP tools imports the knowledge server and with it node:sqlite, whose experimental notice would otherwise land in every commit's output.
  silenceSqliteWarning();
  const t = createT();
  let check: boolean;
  try {
    check = parseArgs({ args: [...argv], options: { check: { type: 'boolean' } }, strict: true }).values.check === true;
  } catch {
    process.stderr.write(`${t('usage')}\n`);
    return 2;
  }
  try {
    const plan = await planTree(REPO_ROOT, t);
    if (check) {
      const stale = staleLines(plan, t);
      process.stdout.write(`${[...(stale.length === 0 ? [t('fresh')] : stale), ...noticeLines(plan, t)].join('\n')}\n`);
      return stale.length === 0 ? 0 : 1;
    }
    await applyPlan(REPO_ROOT, plan);
    process.stdout.write(`${[...changeLines(plan, t), ...noticeLines(plan, t)].join('\n')}\n`);
    return 0;
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    return 1;
  }
}

process.exitCode = await main(process.argv.slice(2));
