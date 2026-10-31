# Proposal

## Why

The config is the one file a person edits by hand, and it was YAML read by a subset parser that refuses flow style, quoted keys, anchors and tabs, so an editor that knows YAML promises more than tagents reads and gives no help on what the keys mean. TOML has one obvious spelling for what the config holds (tables for profiles, arrays of tables for rules), and a JSON Schema gives an editor the keys and their descriptions. Keeping a YAML reader beside the TOML one is a second parser to keep in step for a migration that happens once per machine, so YAML is dropped altogether.

## What Changes

- The config is `config.toml`, found in `$TA_CONFIG`, else `$XDG_CONFIG_HOME/tagents`, else `~/.config/tagents`, with per-machine overlays `config.<host>.toml` that replace whole `a.b` subtrees. A file named by `$TA_CONFIG` is read as TOML whatever its name is.
- Nothing reads YAML. A lone `config.yaml` (or `config.<host>.yaml`, or `plugins/<name>.yaml`) is not looked at; without a `config.toml` tagents says `no config at <dir>/config.toml`.
- The dashboard scripts read TOML with an awk reader that prints `path<TAB>value` lines, a deliberate subset that refuses the rest per line with `file:line`.
- The TypeScript programs (plugin host, `plugin add|remove|list`, knowledge, notify, plugin option files) read TOML through one loader. `plugin add` and `plugin remove` edit the file as text, and a new config is created as `config.toml`.
- `schemas/config.schema.json` (JSON Schema draft 2020-12) describes every key with a description and an example. `config.example.toml` starts with the `#:schema` line that points editors at it. Tests keep the schema, the keys the dashboard reads and the zod schemas of the TypeScript readers in step.
- Docs, skills text and the installer speak of `config.toml` only. The `yaml` dependency of `@tagents/core` is gone; `@tagents/knowledge` keeps it for the YAML frontmatter of its documents, which is a different format.

## Capabilities

### Modified Capabilities
- `configuration`: the file, its lookup, the TOML subset, the overlay, the checker and the schema.
- `plugin-system`: the plugin list, `plugin add|remove` and plugin option files, all TOML.
- `knowledge`: `knowledge.dir` is read from `config.toml`.
- `notify`: the options file is `notify.toml`.

## Impact

- Code: `lib/tagents/config.sh`, `refresh.sh`, `accounts.sh`; `packages/core` (`config-file.ts`, `host.ts`, `plugin-config.ts`, `plugin-options.ts`), `packages/knowledge`, `packages/notify`.
- Files: `config.example.toml` and `schemas/config.schema.json` are new; `config.example.yaml` is gone.
- Dependencies: `smol-toml` in `packages/core`; `ajv` as a dev dependency of `packages/core` for the schema tests; `yaml` leaves `packages/core`.
- Contract: the plugin version moves to 0.10.0 (no `config` verb in the usage), and `contract.json`, the plugin manifest and `skills/tagents/references/` are regenerated.
- Docs: README, `docs/guide/*`, `docs/architecture/overview.md`, the package READMEs and `docs/development.md`.
- A machine that still has only `config.yaml` has no config until it is written as `config.toml`; there is no notice.
