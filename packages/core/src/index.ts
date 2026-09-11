// @tagents/core — how a headless Claude session is spawned, prompted, read and
// listed. The bash dashboard (tagents) owns the tmux side; this package owns
// the sessions that have no pane.
export { tryCatch } from './result.ts';
export { writeAtomic } from './atomic.ts';
export { isAlive } from './pid.ts';

export type {
  PromptOptions,
  SessionDriver,
  SessionRef,
  SessionSpec,
  SessionState,
  StreamEvent,
} from './driver.ts';

export {
  TurnOutcomeSchema,
  clipDetail,
  formatAttemptError,
  outcomeSessionId,
  outcomeText,
  outcomeToolUses,
  succeeded,
} from './turn-outcome.ts';
export type {
  ExitedOutcome,
  KilledAfterResultOutcome,
  OkOutcome,
  SpawnFailedOutcome,
  TimeoutOutcome,
  TurnOutcome,
} from './turn-outcome.ts';

export {
  ClaudeHeadlessDriver,
  DEFAULT_TIMEOUT_MS,
  DISALLOWED_TOOLS,
  PIPE_DRAIN_MS,
  RESULT_EXIT_GRACE_MS,
  TIMEOUT_WARN_BEFORE_MS,
  buildArgs,
  childEnv,
} from './claude-driver.ts';
export type { ClaudeDriverOptions } from './claude-driver.ts';

export { PayloadSchema, StreamReader } from './stream.ts';
export type { ClaudePayload } from './stream.ts';

export {
  HEAD_WINDOW_BYTES,
  MIN_TRANSCRIPT_BYTES,
  SEARCH_HITS,
  SEARCH_SCAN,
  SESSIONS_PROGRAM,
  TAIL_WINDOW_BYTES,
  collect,
  decodeProjectSlug,
  discoverAccounts,
  findByPrefix,
  firstPrompt,
  lastAssistant,
  lastAssistantText,
  renderRecent,
  renderSearch,
  renderShow,
} from './transcripts.ts';
export type { Account, SessionRow } from './transcripts.ts';

export {
  labelsBySession,
  parseStateLine,
  readAgentState,
  readHistory,
  stateDir,
} from './agent-state.ts';
export type { AgentStateRow, HistoryRow } from './agent-state.ts';

export { PLUGIN_API_VERSION, definePlugin } from './plugin.ts';
export type {
  CliCommand,
  CliCommandDef,
  McpTool,
  McpToolDef,
  PluginContext,
  PluginDef,
  ServiceDef,
} from './plugin.ts';

export {
  CONFIG_BASENAME,
  configDir,
  configFile,
  loadPlugin,
  loadPlugins,
  readPluginList,
  resolvePackageDir,
} from './host.ts';
export type { LoadResult, LoadedPlugin, PluginEntry, PluginError, PluginListing } from './host.ts';

export { DEFAULT_LOCALE, createI18n, createT, isLocale, resources } from './i18n/index.ts';
export type { CoreResource, Locale } from './i18n/index.ts';

export { drained, fakeClaude, sleep, tmpDir } from './testkit.ts';
export type { FakeClaude, FakeResult, FakeScript, FakeToolCall } from './testkit.ts';
