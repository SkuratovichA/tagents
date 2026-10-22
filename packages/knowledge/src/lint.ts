// Is the folder still telling the truth?
//
// The loader is tolerant, as OKF asks of a consumer; this is the strict layer.
// Everything here is either a rule of this package's profile that the loader
// let through (a tag that is not a slug, a status nobody knows, an unknown key)
// or a claim a document makes ABOUT ITSELF that can rot without anybody
// touching it: a `generated.at` older than the last commit that changed the
// text, a source that moved on, a link to a document that was renamed, an
// `index.md` that no longer lists what the folder holds. The prose is the
// author's business; these are the machine's.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { realClock } from '@tagents/core';
import {
  DocError,
  LEGACY_KEYS,
  OKF_KEYS,
  SCOPES,
  SLUG,
  STATUSES,
  URL_SCHEME,
  documentLinks,
  fragmentMatches,
  isRealDate,
  isStale,
  listFiles,
  parseDoc,
  parseOffsetDatetime,
  stemOf,
  utcDateOf,
  type KnowledgeDoc,
} from './doc.ts';
import { expandHome } from './paths.ts';
import { INDEX_FILE, indexState, type IndexState } from './toc.ts';
import type { Clock } from './search.ts';
import type { Translate } from './i18n/index.ts';

export type IssueCode =
  | 'frontmatter'
  | 'stem'
  | 'duplicate-id'
  | 'legacy'
  | 'expired'
  | 'stale'
  | 'generated'
  | 'dead-link'
  | 'index';

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

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

/** `by` is a non-empty string and `at` a datetime with an explicit offset. */
function isStamp(v: unknown): boolean {
  return isRecord(v) && typeof v['by'] === 'string' && v['by'].trim() !== '' && parseOffsetDatetime(v['at']) !== null;
}

/** The messages of the profile violations in one document's frontmatter, as `frontmatter` findings. */
function profileProblems(doc: KnowledgeDoc, t: Translate): string[] {
  const raw = doc.raw;
  const out: string[] = [];
  const known = doc.meta.legacy ? [...OKF_KEYS, ...LEGACY_KEYS] : OKF_KEYS;
  for (const key of Object.keys(raw)) if (!known.includes(key)) out.push(t('issueUnknownKey', { key }));

  for (const key of ['title', 'description', 'resource'] as const) {
    const v = raw[key];
    if (v !== undefined && typeof v !== 'string') out.push(t('issueNotString', { key }));
    else if (key === 'description' && typeof v === 'string' && v.trim().includes('\n'))
      out.push(t('issueDescriptionLines'));
  }

  const tags = raw['tags'];
  if (tags !== undefined) {
    if (!Array.isArray(tags)) out.push(t('issueTagsList'));
    else {
      const list: unknown[] = tags;
      for (const tag of list) if (typeof tag !== 'string' || !SLUG.test(tag)) out.push(t('issueTag', { tag: String(tag) }));
    }
  }

  const status = raw['status'];
  if (status !== undefined && !STATUSES.some((s) => s === status)) out.push(t('issueStatus', { value: String(status) }));
  const scope = raw['scope'];
  if (scope !== undefined && !SCOPES.some((s) => s === scope)) out.push(t('issueScope', { value: String(scope) }));

  if (raw['generated'] !== undefined && !isStamp(raw['generated'])) out.push(t('issueGeneratedShape'));
  const verified = raw['verified'];
  if (verified !== undefined) {
    const stamps: unknown[] = Array.isArray(verified) ? verified : [verified];
    if (stamps.length === 0 || !stamps.every(isStamp)) out.push(t('issueVerifiedShape'));
  }

  const staleAfter = raw['stale_after'];
  if (staleAfter !== undefined && parseOffsetDatetime(staleAfter) === null)
    out.push(t('issueStaleAfter', { value: String(staleAfter) }));

  const sources = raw['sources'];
  if (sources !== undefined) {
    if (!Array.isArray(sources)) out.push(t('issueSourcesList'));
    else {
      const list: unknown[] = sources;
      list.forEach((entry, i) => {
        if (!isRecord(entry) || typeof entry['resource'] !== 'string' || entry['resource'].trim() === '')
          out.push(t('issueSourceResource', { n: String(i + 1) }));
      });
    }
  }

  const updated = raw['updated'];
  if (doc.meta.legacy && updated !== undefined && !(typeof updated === 'string' && isRealDate(updated)))
    out.push(t('issueUpdated', { value: String(updated) }));
  return out;
}

/** The existing file a `sources[].resource` names, or null for a URL, a missing file or anything else. */
function sourceFile(dir: string, resource: string): string | null {
  if (URL_SCHEME.test(resource)) return null;
  const rest = expandHome(resource);
  // a leading slash is bundle-relative (OKF); an absolute path is the fallback
  const candidates = rest.startsWith('/') ? [path.join(dir, rest), rest] : [path.resolve(dir, rest)];
  return candidates.find((c) => fs.statSync(c, { throwIfNoEntry: false })?.isFile() === true) ?? null;
}

export function lint(
  dir: string,
  t: Translate,
  env: NodeJS.ProcessEnv = process.env,
  clock: Clock = realClock
): LintResult {
  const issues: Issue[] = [];
  const docs = new Map<string, KnowledgeDoc>();
  const files = listFiles(dir);
  const declaredBy = new Map<string, string>();

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
    docs.set(stem, doc);
    if (!SLUG.test(stem)) issues.push({ file, code: 'stem', message: t('issueStemSlug', { stem }) });
    if (doc.declaredId !== null) {
      if (doc.declaredId !== stem)
        issues.push({ file, code: 'stem', message: t('issueStem', { id: doc.declaredId, stem }) });
      const owner = declaredBy.get(doc.declaredId);
      if (owner === undefined) declaredBy.set(doc.declaredId, file);
      else
        issues.push({
          file,
          code: 'duplicate-id',
          message: t('issueDuplicateId', { id: doc.declaredId, other: path.basename(owner) }),
        });
    }
    if (doc.meta.legacy) issues.push({ file, code: 'legacy', message: t('issueLegacy') });
    for (const message of profileProblems(doc, t))
      issues.push({ file, code: 'frontmatter', message });
  }

  // The git check only makes sense where there is history to compare against:
  // a folder that is not a repo, or a document not committed yet, is not stale.
  const git = insideGitRepo(dir, env);
  for (const doc of docs.values()) {
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

    if (doc.meta.staleAfter !== undefined && isStale(doc.meta.staleAfter, clock.now()))
      issues.push({ file: doc.path, code: 'expired', message: t('issueExpired', { value: doc.meta.staleAfter }) });

    if (generatedOn !== null)
      for (const { resource } of doc.meta.sources) {
        const source = sourceFile(dir, resource);
        if (source === null) continue; // a URL, or not on this machine: nothing to compare
        const changed = utcDate(fs.statSync(source).mtimeMs);
        if (changed > generatedOn)
          issues.push({
            file: doc.path,
            code: 'generated',
            message: t('issueGenerated', { source: resource, changed, updated: generatedOn }),
          });
      }

    for (const link of documentLinks(doc.body)) {
      const target = docs.get(link.id);
      const fragment = link.fragment;
      const dead =
        target === undefined ||
        (fragment !== null &&
          !target.chunks.some((c) =>
            link.form === 'wiki'
              ? c.heading.toLowerCase() === fragment.toLowerCase()
              : fragmentMatches(fragment, c.heading)
          ));
      if (dead) issues.push({ file: doc.path, code: 'dead-link', message: t('issueDeadLink', { link: link.raw }) });
    }
  }

  // The same documents `toc` would list: the ones the loader accepts.
  const state: IndexState = indexState(
    dir,
    [...docs.values()].filter((d) => SLUG.test(d.meta.id))
  );
  if (state !== 'current')
    issues.push({
      file: path.join(dir, INDEX_FILE),
      code: 'index',
      message: t(state === 'missing' ? 'issueIndexMissing' : 'issueIndexOutdated'),
    });

  return { checked: files.length, issues };
}
