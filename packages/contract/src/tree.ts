// The only module that touches the file system: reads the tree the plan is made from, and applies a plan to it. A check never calls applyPlan.
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createT, type Translate } from './i18n/index.ts';
import { isMissing } from './missing.ts';
import { CONTRACT_FILE, MARKETPLACE_FILE, PLUGIN_FILE, SKILLS_DIR, planGenerate, type Disk, type Plan } from './plan.ts';
import { collectSources } from './sources.ts';

/** The repo root: this file is `<root>/packages/contract/src/tree.ts`. */
export const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

/** Files an operating system drops into a folder; they are no part of what the plugin ships. */
const IGNORED = new Set(['.DS_Store']);

/** Every file under skills/, relative to the root with POSIX separators. */
async function skillFiles(root: string): Promise<string[]> {
  try {
    const entries = await fs.readdir(path.join(root, SKILLS_DIR), { recursive: true, withFileTypes: true });
    return entries
      .filter((entry) => entry.isFile() && !IGNORED.has(entry.name))
      .map((entry) => path.relative(root, path.join(entry.parentPath, entry.name)).split(path.sep).join('/'));
  } catch (error) {
    if (!isMissing(error)) throw error;
    return [];
  }
}

export async function readDisk(root: string): Promise<Disk> {
  const files = new Map<string, Uint8Array>();
  const add = async (relative: string): Promise<void> => {
    try {
      files.set(relative, await fs.readFile(path.join(root, relative)));
    } catch (error) {
      if (!isMissing(error)) throw error;
    }
  };
  await Promise.all([CONTRACT_FILE, PLUGIN_FILE, MARKETPLACE_FILE, ...(await skillFiles(root))].map(add));
  return { files };
}

/** Reads the code and the tree and returns what a generation would change; writes nothing. */
export async function planTree(root: string = REPO_ROOT, t: Translate = createT()): Promise<Plan> {
  const [sources, disk] = await Promise.all([collectSources(root, t), readDisk(root)]);
  return planGenerate(sources, disk, t);
}

export async function applyPlan(root: string, plan: Plan): Promise<void> {
  for (const [relative, content] of plan.writes) {
    await fs.mkdir(path.dirname(path.join(root, relative)), { recursive: true });
    await fs.writeFile(path.join(root, relative), content);
  }
  for (const relative of plan.deletes) await fs.rm(path.join(root, relative), { force: true });
}

/** What a check says about a stale tree, one line per path and then what to run. Empty when nothing is stale. */
export function staleLines(plan: Plan, t: Translate): string[] {
  return plan.stale.length === 0 ? [] : [...plan.stale.map((p) => t('stale', { path: p })), t('staleHint')];
}

/** What is worth knowing about the sources and is not a reason to fail: the verbs that declare no effect. Empty when there is nothing to say. */
export function noticeLines(plan: Plan, t: Translate): string[] {
  return plan.unclassified.length === 0 ? [] : [t('unclassified', { verbs: plan.unclassified.join(', ') })];
}

/** What a generation says it did, one line per change. */
export function changeLines(plan: Plan, t: Translate): string[] {
  const lines = [
    ...[...plan.writes.keys()].map((p) => t('wrote', { path: p })),
    ...plan.deletes.map((p) => t('deleted', { path: p })),
  ];
  if (plan.move === 'first') lines.push(t('versionFirst', { digest: plan.digest, version: plan.versionTo }));
  if (plan.move === 'minor') lines.push(t('versionMinor', { from: plan.versionFrom, to: plan.versionTo }));
  if (plan.move === 'patch') lines.push(t('versionPatch', { from: plan.versionFrom, to: plan.versionTo }));
  return lines.length === 0 ? [t('upToDate')] : lines;
}
