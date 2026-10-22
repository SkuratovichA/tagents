// Is the folder still telling the truth?
//
// Everything here is a claim a document makes ABOUT ITSELF that can rot
// without anybody touching the document: an id that no longer matches the
// file, an `updated:` older than the last commit that changed the text, a
// `generated_from:` whose source moved on, a link to a document that was
// renamed. The prose is the author's business; these are the machine's.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import {
  DocError,
  listFiles,
  parseDoc,
  stemOf,
  utcDateOf,
  wikilinks,
  type KnowledgeDoc,
} from './doc.ts';
import { expandHome } from './paths.ts';
import type { Translate } from './i18n/index.ts';

export type IssueCode = 'frontmatter' | 'stem' | 'duplicate-id' | 'stale' | 'generated' | 'dead-link';

export interface Issue {
  readonly file: string;
  readonly code: IssueCode;
  readonly message: string;
}

export interface LintResult {
  readonly checked: number;
  readonly issues: readonly Issue[];
}

/** The date of the newest commit that touched `file`, or null. */
export function lastCommitDate(file: string, env: NodeJS.ProcessEnv = process.env): string | null {
  const r = spawnSync('git', ['-C', path.dirname(file), 'log', '-1', '--format=%cs', '--', file], {
    encoding: 'utf8',
    env,
  });
  if (r.error || r.status !== 0) return null;
  const date = r.stdout.trim();
  return /^\d{4}-\d{2}-\d{2}$/.test(date) ? date : null;
}

export function insideGitRepo(dir: string, env: NodeJS.ProcessEnv = process.env): boolean {
  const r = spawnSync('git', ['-C', dir, 'rev-parse', '--is-inside-work-tree'], {
    encoding: 'utf8',
    env,
  });
  return !r.error && r.status === 0 && r.stdout.trim() === 'true';
}

function utcDate(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10);
}

export function lint(dir: string, t: Translate, env: NodeJS.ProcessEnv = process.env): LintResult {
  const issues: Issue[] = [];
  const docs = new Map<string, KnowledgeDoc>();
  const files = listFiles(dir);
  const idOwner = new Map<string, string>();

  for (const file of files) {
    let doc: KnowledgeDoc;
    try {
      doc = parseDoc(file, fs.readFileSync(file, 'utf8'));
    } catch (e) {
      const detail = e instanceof DocError ? e.message : (e as Error).message;
      issues.push({ file, code: 'frontmatter', message: t('issueFrontmatter', { detail }) });
      continue;
    }
    const stem = stemOf(file);
    const declared = doc.declaredId ?? stem;
    if (declared !== stem)
      issues.push({ file, code: 'stem', message: t('issueStem', { id: declared, stem }) });
    const owner = idOwner.get(declared);
    if (owner !== undefined) {
      issues.push({
        file,
        code: 'duplicate-id',
        message: t('issueDuplicateId', { id: declared, other: path.basename(owner) }),
      });
      continue;
    }
    idOwner.set(declared, file);
    docs.set(stem, doc);
  }

  // The git check only makes sense where there is history to compare against:
  // a folder that is not a repo, or a document not committed yet, is not stale.
  const git = insideGitRepo(dir, env);
  for (const doc of docs.values()) {
    // Minimum edit for the OKF loader: the dates come from `generated.at`, and a
    // legacy `generated_from` is now its one source.
    const generatedOn = utcDateOf(doc.meta.generated?.at);
    if (git && generatedOn !== null) {
      const commit = lastCommitDate(doc.path, env);
      if (commit !== null && generatedOn < commit)
        issues.push({
          file: doc.path,
          code: 'stale',
          message: t('issueStale', { updated: generatedOn, commit }),
        });
    }

    for (const { resource: from } of doc.meta.sources) {
      if (generatedOn === null) break;
      const source = path.resolve(dir, expandHome(from));
      let mtimeMs: number | null = null;
      try {
        mtimeMs = fs.statSync(source).mtimeMs;
      } catch {
        mtimeMs = null; // the source is not on this machine: nothing to compare
      }
      if (mtimeMs !== null) {
        const changed = utcDate(mtimeMs);
        if (changed > generatedOn)
          issues.push({
            file: doc.path,
            code: 'generated',
            message: t('issueGenerated', { source: from, changed, updated: generatedOn }),
          });
      }
    }

    for (const link of wikilinks(doc.body)) {
      const target = docs.get(link.id);
      const dead =
        target === undefined ||
        (link.heading !== null &&
          !target.chunks.some((c) => c.heading.toLowerCase() === link.heading?.toLowerCase()));
      if (dead)
        issues.push({
          file: doc.path,
          code: 'dead-link',
          message: t('issueDeadLink', {
            target: link.heading === null ? link.id : `${link.id}#${link.heading}`,
          }),
        });
    }
  }

  return { checked: files.length, issues };
}
