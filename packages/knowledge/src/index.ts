// @tagents/knowledge — the owner's operational knowledge as documents a
// machine can search: a frontmatter format, a SQLite FTS5 index over the '## '
// sections, a CLI and an MCP server. Writes are git's job; nothing here has a
// write path into the documents.
export {
  DocError,
  FrontmatterSchema,
  KINDS,
  SCOPES,
  SLUG,
  WIKILINK,
  chunk,
  hashOf,
  listFiles,
  loadDir,
  parseDoc,
  readDoc,
  splitFrontmatter,
  stemOf,
  wikilinks,
} from './doc.ts';
export type { Chunk, Frontmatter, KnowledgeDoc, Kind, LoadResult, Scope, Wikilink } from './doc.ts';

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
export type { DocSummary, Filters, Hit, SearchOptions, Section } from './search.ts';

export { insideGitRepo, lastCommitDate, lint } from './lint.ts';
export type { Issue, IssueCode, LintResult } from './lint.ts';

export { DB_BASENAME, configuredDir, expandHome, resolveDb, resolveDir } from './paths.ts';
export type { DirResult } from './paths.ts';

export { DEFAULT_LOCALE, createT, interpolate, isLocale, resources } from './i18n/index.ts';
export type { KnowledgeKey, KnowledgeResource, Locale, Translate, Vars } from './i18n/index.ts';

export { MAX_SESSIONS, SERVER_NAME, SERVER_VERSION, createServer, runMcp } from './mcp/server.ts';
