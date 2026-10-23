// @tagents/knowledge — the owner's operational knowledge as documents a
// machine can search: a frontmatter format, a SQLite FTS5 index over the '## '
// sections, a CLI and an MCP server. Writes are git's job; nothing here has a
// write path into the documents.
export {
  DocError,
  LEGACY_KEYS,
  OKF_KEYS,
  RESERVED_FILES,
  SCOPES,
  SLUG,
  STATUSES,
  WIKILINK,
  chunk,
  documentLinks,
  fragmentMatches,
  hashOf,
  headingSlug,
  isRealDate,
  isStale,
  listFiles,
  loadDir,
  parseDoc,
  parseOffsetDatetime,
  readDoc,
  splitFrontmatter,
  stemOf,
  utcDateOf,
  wikilinks,
} from './doc.ts';
export type {
  Chunk,
  DocLink,
  Frontmatter,
  Generated,
  KnowledgeDoc,
  LoadResult,
  Scope,
  Source,
  Status,
  Wikilink,
} from './doc.ts';

export { SCHEMA_VERSION, TOKENIZER, docCount, openDb, reindex, silenceSqliteWarning } from './db.ts';
export type { IndexStats, Row } from './db.ts';

export {
  BODY_WEIGHT,
  DEFAULT_LIMIT,
  HEADING_WEIGHT,
  SNIPPET_TOKENS,
  ftsQuery,
  getDoc,
  getSection,
  listDocs,
  parseAddress,
  search,
} from './search.ts';
export type { Clock, DocSummary, Filters, Hit, Lifecycle, SearchOptions, Section, Timed } from './search.ts';

export { insideGitRepo, lastCommitDate, lint } from './lint.ts';
export type { Issue, IssueCode, LintResult } from './lint.ts';

export { INDEX_FILE, indexState, renderIndex, writeIndex } from './toc.ts';
export type { IndexState } from './toc.ts';

export { DB_BASENAME, USAGE_BASENAME, configuredDir, expandHome, resolveDb, resolveDir, resolveUsageDb } from './paths.ts';
export type { DirResult } from './paths.ts';

export {
  BUSY_TIMEOUT_MS,
  DEFAULT_MIN_DAYS,
  DEFAULT_MIN_GETS,
  DEFAULT_SINCE_DAYS,
  DEFAULT_TOP,
  RETENTION_DAYS,
  UsageStoreError,
  appendEvents,
  callerFrom,
  callerFromEnv,
  getEvent,
  hitEvents,
  openUsageDb,
  parsePositive,
  parseSince,
  readUsageRows,
  recordReads,
  usageRows,
} from './usage.ts';
export type { RecordOptions, ReportOptions, UsageEvent, UsageKind, UsageRow } from './usage.ts';

export { DEFAULT_LOCALE, createT, interpolate, isLocale, resources } from './i18n/index.ts';
export type { KnowledgeKey, KnowledgeResource, Locale, Translate, Vars } from './i18n/index.ts';

export { MAX_SESSIONS, SERVER_NAME, SERVER_VERSION, createServer, runMcp } from './mcp/server.ts';
