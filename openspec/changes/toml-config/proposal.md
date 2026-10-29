# Proposal

## Why

The config is the one file a person edits by hand, and it is YAML read by a subset parser that refuses flow style, quoted keys, anchors and tabs, so an editor that knows YAML promises more than tagents reads and gives no help on what the keys mean. TOML has one obvious spelling for what the config holds (tables for profiles, arrays of tables for rules), a JSON Schema can describe it to every TOML-aware editor (completion, hover text, a squiggle under a misspelt key), and a reader for the subset is small enough to keep in awk next to the YAML one. The owner's own config stays YAML for now, so YAML keeps working, says it is deprecated, and has a converter that does not touch it.

## What Changes

- The config is `config.toml`, found where `config.yaml` was (`$TA_CONFIG`, else `$XDG_CONFIG_HOME/tagents`, else `~/.config/tagents`), with per-machine overlays `config.<host>.toml` that replace whole `a.b` subtrees exactly as before. With `$TA_CONFIG` the file's extension picks the reader.
- `config.yaml` (and `config.<host>.yaml`) is still read when there is no TOML twin, exactly as it was. It is reported as deprecated, with the command that fixes it, by `tagents --check`, the dashboard header and the status bar tally, and once per process on stderr by the TypeScript programs. When both `config.toml` and `config.yaml` exist the TOML wins and the same places name both files.
- The dashboard scripts read TOML with a second awk reader that emits the same `path<TAB>value` stream as the YAML one, so `tagents --config` prints identical lines for a config and its conversion. It reads a deliberate subset and refuses the rest per line with `file:line`.
- The TypeScript programs (plugin host, `plugin add|remove|list`, knowledge, notify, plugin option files) choose their parser by extension through one loader. `plugin add` and `plugin remove` edit the file in use, a TOML config as text and a YAML config as before, and a new config is created as `config.toml`.
- `tagents config convert [FILE] [--write] [--all]` turns the YAML config into TOML. By default it prints and changes nothing; `--write` creates the `.toml` beside the YAML, refuses to overwrite and never touches the YAML; `--all` also converts the per-host overlays, all or none. Before offering a byte it reads both files with `tagents --config` and compares.
- `schemas/config.schema.json` (JSON Schema draft 2020-12) describes every key with a description and an example. `config.example.toml`, which replaces `config.example.yaml`, starts with the `#:schema` line that points editors at it. Tests keep the schema, the keys the dashboard reads and the zod schemas of the TypeScript readers from drifting apart.
- Docs, skills text and the installer speak of `config.toml`; the YAML example moves to `tests/fixtures/` as the converter's input.

## Capabilities

### Modified Capabilities
- `configuration`: the file, its lookup, the TOML subset, the YAML fallback and its notices, the overlay in both formats, the converter and the schema.
- `plugin-system`: the plugin list, `plugin add|remove` and plugin option files in either format, and the new reserved verb `config`.
- `knowledge`: `knowledge.dir` is read from either format.
- `notify`: the options file is `notify.toml`, with `notify.yaml` still read.

## Impact

- Code: `lib/tagents/config.sh`, `refresh.sh`, `accounts.sh`; `packages/core` (`config-file.ts`, `config-convert.ts`, `cli/config.ts`, `host.ts`, `plugin-config.ts`, `plugin-options.ts`), `packages/knowledge`, `packages/notify`.
- Files: `config.example.toml` and `schemas/config.schema.json` are new; `config.example.yaml` moves to `tests/fixtures/config.example.yaml`.
- Dependencies: `smol-toml` in `packages/core`; `ajv` as a dev dependency of `packages/core` for the schema tests.
- Contract: a new CLI verb, so `contract.json`, the plugin manifest digest and `skills/tagents/references/` are regenerated.
- Docs: README, `docs/guide/*`, `docs/architecture/overview.md`, the package READMEs and `docs/development.md` (a row for the new suite).
- Existing YAML configs keep working unchanged apart from one added line in `tagents --check` while they are YAML.
