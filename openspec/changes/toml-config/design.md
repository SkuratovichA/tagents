## Decisions to review

**One file name, two formats, found by the same rules.** `config.toml` is looked for where `config.yaml` was, with the same per-machine overlay, and with `$TA_CONFIG` the extension picks the reader, because a person who already points `$TA_CONFIG` at a file should not learn a second variable. Rejected: a `TA_CONFIG_FORMAT` variable, which nobody would remember to set.

```sh
# lib/tagents/config.sh, cfg_read: the extension decides
case $1 in
  *.toml) cfg_parse_toml "$1" <"$1" ;;
  *)      cfg_parse "$1" <"$1" ;;
esac
```

**TOML wins over YAML, and says so.** When both files are there the TOML is read, because whoever wrote `config.toml` meant it, and `tagents --check` names both files so the leftover YAML gets deleted rather than forgotten. Rejected: reading YAML until the TOML is "ready" (the file just written would be silently ignored) and refusing to start (a good config would stop working because of a stray file).

```
~/.config/tagents/config.toml: config.yaml is also there — config.toml is read and config.yaml is ignored; delete config.yaml once config.toml is right
```

**A YAML config is a counted problem, not a banner.** The deprecation is one more line in `tagents --check`, so the dashboard header, the status bar tally and the one-time tmux message carry it with no new surface; the TypeScript programs, which have no header, say it once per process on stderr. Rejected: a warning on every read (the status bar reads the config constantly) and no warning at all (the fallback would never be left). The note also applies to a YAML file named by `$TA_CONFIG`, and `tagents --config` stays silent so its output is data only.

```sh
# lib/tagents/config.sh, cfg_format_notes: a YAML main config is one more problem
case $CONFIG_FILE in
  *.toml) … ;;   # the twin note goes here
  *) cfg_note '' "YAML config is deprecated — run: tagents config convert (it prints the TOML and changes nothing; --write saves it beside this file)" "$CONFIG_FILE" ;;
esac
```

**The dashboard reads TOML with a second awk reader that emits the same stream.** `cfg_parse_toml` prints the `path<TAB>value` lines that `cfg_parse` prints for YAML, so `cfg_get`, `cfg_children` and the overlay code do not know which format they got, and `tagents --config` of a config and of its conversion can be compared byte for byte. The dashboard runs on bash 3.2 with the awk macOS ships and no `yq`, and starting node on every status bar redraw is not an option. Rejected: shelling out to a TOML library from the dashboard, and a full TOML reader in awk (dates, multi-line strings and hexadecimal are not things this config holds, so they are refused by line instead).

```
[claude.profiles.personal]          claude.profiles.personal<TAB>
config_dir = "~/.claude"            claude.profiles.personal.config_dir<TAB>~/.claude
[[claude.rules]]                    claude.rules.0 …  (the next one is claude.rules.1)
args = ["--model", "opus"]          claude.args.0<TAB>--model   claude.args.1<TAB>opus
```

**The subset is stricter than TOML where the reader would otherwise guess.** Only `\"` and `\\` escapes in basic strings, decimal numbers only, a table or a key defined twice is refused, and nothing may follow a value but a comment. Every refusal is `tagents: config: <file>:<line>: <why>` and costs only its line, the contract the YAML reader already has. Rejected: accepting `\u` and the rest and getting one wrong. A cross-reader test (`packages/core/test/config-convert.test.ts`) feeds one file to smol-toml and to the awk reader so the two cannot disagree silently.

**The TypeScript side picks the parser by extension in one module.** `packages/core/src/config-file.ts` is the only place that knows `smol-toml` and `yaml` are both there; the plugin host, `plugin add|remove|list`, the knowledge folder lookup, plugin option files and the converter all go through it, and each caller keeps validating the result with its own zod schema. Rejected: every reader choosing its own parser, which is how the formats would drift.

```ts
export function parseConfigText(text: string, format: ConfigFormat): unknown {
  return format === 'toml' ? parseToml(text) : (parseYaml(text) ?? {});
}
```

**`plugin add` and `plugin remove` edit text, in whichever format the file is.** A TOML config gets `[plugins.NAME]` appended after everything else behind one blank line (a table header at the end of a file is valid whatever precedes it, so nothing has to be understood to place it), removal cuts that table, its sub-tables and the comment lines that belong to its header, and the result is parsed again before it is written. A new config is created as `config.toml`; a YAML config is edited as before. Rejected: parse and serialise, which loses comments and the spacing somebody aligned by hand.

```ts
const tomlEntry = (name: string, from: string) => `[plugins.${tomlKey(name)}]\nfrom = ${JSON.stringify(from)}\n`;
```

**Plugin option files prefer `<name>.toml` and fall back to `<name>.yaml`, silently.** `notify.toml` is the file the docs show, and the notify watcher watches both names so a move from one to the other while the service runs is seen. No deprecation line, because `config convert` converts the main config and its overlays and cannot fix an options file, and a notice that names a command which does not help is noise. Rejected: converting options files too (they are optional, per plugin and owned by plugin authors).

**The converter prints by default, writes beside the source, and proves what it wrote.** `tagents config convert` changes nothing; `--write` creates `config.toml` next to `config.yaml`, refuses to overwrite and never edits or deletes the YAML, which is the owner's live config; `--all` adds the per-host overlays and writes all of them or none. Before it offers a byte it reads the YAML and the TOML it made with `tagents --config` (the dashboard's own reader, not a second opinion) and compares the two dumps. Rejected: converting in place or renaming the YAML to `.bak` (the source is touched), and carrying comments over (the YAML parser attaches comments to nodes, not to the lines a person meant them for, so the result would be guesses; the command says comments are not carried over).

```ts
const before = dumpOf(tagents, yamlFile, scratch);
const after = dumpOf(tagents, tomlFile, scratch);
if (!sameConfig(before.dump, after.dump)) return refused(`${file}: tagents would read the TOML made from it differently from the YAML, so nothing is offered`);
```

**The comparison allows one reordering, because TOML forces it.** A TOML table's plain keys must come before its sub-tables, so a YAML key written after a sub-table moves up; `sameConfig` accepts that and nothing else (same set of lines, and the same order of keys within the plain keys and within the sub-tables of each parent). The order of the profiles is compared strictly, because it is the order of the account picker. Rejected: demanding identical bytes, which would refuse legitimate configs, and ignoring order, which could reorder the account picker.

**Types come from the YAML text, not from the YAML parser.** A number or boolean is written bare only when the source wrote it as a plain `850` or `true`; everything else becomes a string. The dashboard's dump prints every value as text, so `1.0` read as the number 1 and written back would print `1`, a different dump. An empty value becomes an empty table, which is what the bash reader makes of `work:`. Rejected: typing from the parsed value.

**The JSON Schema is written by hand and pinned by tests.** The dashboard's keys are read by bash, so no TypeScript type holds them and nothing could generate the schema. `schemas/config.schema.json` has a `description` and an `examples` entry on every key, and `config.example.toml` starts with `#:schema <URL>`, which TOML-aware editors (taplo, the Even Better TOML extension) follow. Three tests keep it honest: a scan of every `cfg_get`, `cfg_children`, `cfg_check` case label and the key-binding defaults in `lib/tagents` against the schema in both directions; the zod schemas for `plugins.*` and `knowledge` against the schema's subtrees; and `config.example.toml`, the YAML example and the converter's output validated with ajv. A mutation of either side makes a test fail. Rejected: generating the schema from zod, which covers two of the seven tables.

```ts
// packages/core/test/config-schema.test.ts
test('every key the dashboard reads is in the schema', () => {
  for (const key of keysTheDashboardReads()) assert.ok(inSchema(key), `${key} is read by lib/tagents but not in the schema`);
});
```

**The schema is strict where bash owns the table and permissive where zod does.** `claude`, `usage`, `notes`, `resurrect` and `keys` forbid unknown keys, so a misspelt `monthly_limit` is flagged in the editor; `plugins.*` and `knowledge` allow other keys, as their zod schemas do. The cost is that a key tagents ignores but a config still carries (`dashboard.layout`, dropped when the cockpit became the only layout) is flagged too, which is what a stale key deserves. Rejected: strict everywhere, which would flag keys a plugin legitimately reads.

**`config.example.toml` replaces `config.example.yaml`; the YAML example is a converter fixture.** One example to keep in step, and the old one stays as the input that the equivalence test converts. Rejected: shipping both.

**The existing shell suites use TOML fixtures.** A YAML config now counts as a problem, so a suite that builds its config in YAML gets a changed tally for a reason that has nothing to do with what it tests. `tests/ui.sh`, `tests/forks.sh`, `tests/refresh.sh`, `tests/cockpit.sh` and `tests/config.sh` write TOML, and the YAML cases stay where YAML is the point (`tests/config.sh` for the subset, `tests/config-toml.sh` for the fallback). Rejected: leaving them in YAML and raising the expected counts, which would test the deprecated path everywhere and the supported one nowhere.

**`config` joins the reserved verbs.** `tagents config convert` reaches `tagents-core` through the forwarding the bash script already does for any verb it does not know, so the dashboard script has no new dispatch. A plugin that is keyed `config` still loads and is unreachable as a verb, as for the other reserved words. Rejected: a flag such as `tagents --convert-config`, which would be a second way to reach a core verb.

## Open questions for Sasha

1. When does the YAML fallback go? It is read today, says it is deprecated, and has a converter; the spec does not name a removal date, so it stays until you say.
2. Should your live config be converted after the merge? The PR body has the dry-run commands; `tagents config convert` first prints the TOML and changes nothing, and `--write` is only worth it once you have read the output.
3. Is it acceptable that the converter drops comments? Carrying them over is guesswork (see above); the alternative is converting the live config by hand, with the schema open in your editor.
4. The schema is addressed by the raw GitHub URL on `main`, so editors resolve it only after this merges. Do you want it pinned to a tag once there is one?
5. Should the schema flag keys the dashboard ignores in the tables bash owns? Today it does (the configuration spec says an unknown key is ignored, so tagents itself never complains); allowing them would hide a misspelt key from the editor.
