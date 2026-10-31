## Decisions to review

**There is one format, TOML.** `config.toml` is where the config lives, with per-machine overlays `config.<host>.toml` that replace whole `a.b` subtrees, and a plugin's options in `plugins/<name>.toml`. Nothing reads YAML: a lone `config.yaml` is not looked at and the message says which `config.toml` was expected, and a file pointed at with `$TA_CONFIG` is read as TOML whatever it is called. A first version of this change kept a YAML fallback with a deprecation notice and a `tagents config convert` verb; both went before the change was archived, because a fallback is a second reader to keep in step for a one-time migration that was done by hand. Rejected: a removal date for the fallback, which only postpones the same deletion.

**The dashboard reads TOML with one awk reader.** `cfg_parse_toml` prints one `path<TAB>value` line per leaf, and `cfg_get`, `cfg_children` and the overlay code work on that stream. The dashboard runs on bash 3.2 with the awk macOS ships and no `yq`, and starting node on every status bar redraw is not an option. Rejected: shelling out to a TOML library from the dashboard, and a full TOML reader in awk (dates, multi-line strings and hexadecimal are not things this config holds, so they are refused by line instead).

```
[claude.profiles.personal]          claude.profiles.personal<TAB>
config_dir = "~/.claude"            claude.profiles.personal.config_dir<TAB>~/.claude
[[claude.rules]]                    claude.rules.0 …  (the next one is claude.rules.1)
args = ["--model", "opus"]          claude.args.0<TAB>--model   claude.args.1<TAB>opus
```

**The subset is stricter than TOML where the reader would otherwise guess.** Only `\"` and `\\` escapes in basic strings, decimal numbers only, a table or a key defined twice is refused, and nothing may follow a value but a comment. Every refusal is `tagents: config: <file>:<line>: <why>` and costs only its line. Rejected: accepting `\u` and the rest and getting one wrong.

**The TypeScript side reads TOML in one module.** `packages/core/src/config-file.ts` is the only place that knows `smol-toml`; the plugin host, `plugin add|remove|list`, the knowledge folder lookup and plugin option files go through it, and each caller keeps validating the result with its own zod schema. Rejected: every reader choosing its own parser, which is how the readers would drift.

**`plugin add` and `plugin remove` edit text.** A new entry is a `[plugins.NAME]` table appended after everything else behind one blank line; removing one cuts its table and the comments just above the next header that belong to it. The result is parsed again before it is written, so a bad edit is refused and the file is untouched. Rejected: parse, edit and re-serialise, which loses comments and hand-aligned spacing.

**Plugin option files are `<name>.toml`.** The notify watcher watches that one file; replacing a symlink reloads it, editing its target does not.

**The JSON Schema is written by hand and pinned by tests.** The dashboard's keys are read by bash, so no TypeScript type holds them and nothing could generate the schema. `schemas/config.schema.json` has a `description` and an `examples` entry on every key, and `config.example.toml` starts with `#:schema <URL>`, which TOML-aware editors (taplo, the Even Better TOML extension) follow. Three tests keep it honest: a scan of every `cfg_get`, `cfg_children`, `cfg_check` case label and the key-binding defaults in `lib/tagents` against the schema in both directions; the zod schemas for `plugins.*` and `knowledge` against the schema's subtrees; and `config.example.toml` validated with ajv. A mutation of either side makes a test fail. Rejected: generating the schema from zod, which covers two of the seven tables. `taplo` is not installed in CI, because the workflow runs no JavaScript test and downloading a binary there adds a supply-chain step for one lint; the schema test runs `taplo lint` on the example when `taplo` is on PATH, says it skipped when it is not, and the lint was run locally.

```ts
// packages/core/test/config-schema.test.ts
test('every key the dashboard reads is in the schema', () => {
  for (const key of keysTheDashboardReads()) assert.ok(inSchema(key), `${key} is read by lib/tagents but not in the schema`);
});
```

**The schema is strict where bash owns the table and permissive where zod does.** `claude`, `usage`, `notes`, `resurrect` and `keys` forbid unknown keys, so a misspelt `monthly_limit` is flagged in the editor; `plugins.*` and `knowledge` allow other keys, as their zod schemas do. The cost is that a key tagents ignores but a config still carries (`dashboard.layout`, dropped when the cockpit became the only layout) is flagged too, which is what a stale key deserves. Rejected: strict everywhere, which would flag keys a plugin legitimately reads.

**`config.example.toml` is the one example.** It starts with the `#:schema` line, and `tests/config.sh` pins what it flattens to.

**The shell suites write TOML fixtures.** `tests/config-toml.sh` covers the reader (the subset, the refusals, which file is read, the overlay, `--check`) and the other suites build their config as TOML.
