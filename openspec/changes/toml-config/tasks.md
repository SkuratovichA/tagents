## 1. The dashboard reads TOML

- [x] 1.1 Add `cfg_parse_toml` to `lib/tagents/config.sh`: the TOML subset flattened into the `path<TAB>value` stream of the YAML reader, every construct outside it refused per line with `file:line`. Proved by `tests/config-toml.sh` sections 1 and 2.
- [x] 1.2 Choose the file in `cfg_resolve`: `$TA_CONFIG` verbatim with the extension picking the reader, else `config.toml`, else `config.yaml`, else `config.toml` as the named path. Proved by `tests/config-toml.sh` section 3.
- [x] 1.3 Read the per-machine overlay in either format (`config.<host>.toml`, else `config.<host>.yaml`), each by its own reader, with whole `a.b` subtrees replaced as before. Proved by `tests/config-toml.sh` section 4 and `tests/config.sh`.
- [x] 1.4 Report a YAML main config or overlay as a deprecated problem and a TOML beside a YAML as ignored, in `tagents --check`, the header, the status bar tally and the one-time tmux message, with the status bar's `.cfg-check` stamp watching every `config*.toml` and `config*.yaml`. Proved by `tests/config-toml.sh` section 5.
- [x] 1.5 Make the refresher and `lib/tagents/accounts.sh` follow the file in use and watch both overlay names. Proved by `tests/refresh.sh` and `tests/forks.sh`.

## 2. The TypeScript programs read TOML

- [x] 2.1 Add `packages/core/src/config-file.ts`: the file in use, the parser by extension, the once-per-process notices. Proved by `packages/core/test/config-file.test.ts`.
- [x] 2.2 Make the plugin host, `plugin list` and `plugin add|remove` use it, with `plugin add` creating `config.toml` and editing TOML and YAML configs as text. Proved by `packages/core/test/plugin-host.test.ts`, `plugin-cli.test.ts` and `plugin-commands.test.ts`.
- [x] 2.3 Read plugin option files from `<name>.toml`, else `<name>.yaml`. Proved by `packages/core/test/plugin-options.test.ts`.
- [x] 2.4 Read `knowledge.dir` from either format and show the snippet in the format of the config. Proved by `packages/knowledge/test/config.test.ts`.
- [x] 2.5 Make the notify service reload when either `notify.toml` or `notify.yaml` changes. Proved by `packages/notify/test/service.test.ts` and `commands.test.ts`.
- [x] 2.6 Reserve `config` as a core verb and list `config convert [FILE] [--write] [--all]` in the usage. Proved by `packages/core/test/cli-spec.test.ts` and `cli.test.ts`, and `pnpm plugin:check` for the regenerated contract.

## 3. The converter

- [x] 3.1 Add `tagents config convert`: TOML on stdout by default, `--write` beside the source without overwriting or touching the YAML, `--all` for the overlays, all or nothing. Proved by `packages/core/test/config-convert.test.ts`.
- [x] 3.2 Verify every conversion with `tagents --config` on both files before offering a byte, and refuse constructs with no TOML twin with `file:line`. Proved by `packages/core/test/config-convert.test.ts`, including the example converted under `/bin/bash` 3.2 and dumped to identical bytes.

## 4. The schema

- [x] 4.1 Write `schemas/config.schema.json` and `config.example.toml` (which replaces `config.example.yaml`, moved to `tests/fixtures/`). Proved by `packages/core/test/config-schema.test.ts`: valid draft 2020-12, a description and an example on every key, the example and the converter's output validate.
- [x] 4.2 Pin the schema to the keys the dashboard reads and to the zod schemas of the TypeScript readers. Proved by `packages/core/test/config-schema.test.ts` and `packages/knowledge/test/config-schema.test.ts`.
- [x] 4.3 Lint the example with the schema in taplo. Proved by `taplo lint` in `packages/core/test/config-schema.test.ts`.

## 5. The existing suites

- [x] 5.1 Write the config of `tests/ui.sh`, `tests/forks.sh`, `tests/refresh.sh`, `tests/cockpit.sh` and `tests/config.sh` as TOML, keeping YAML cases where YAML is what is tested. Proved by `bash tests/<suite>.sh` for each.

## 6. Docs and specs

- [x] 6.1 Bring the README, `docs/`, the package READMEs, the skill text, the installer and the header comments to `config.toml`, and add the new suite to the table in `docs/development.md`. Proved by `pnpm docs:build` and a `grep -rn "config.yaml"` that finds only the fallback, the converter and the fixtures.
- [x] 6.2 Write the deltas in this change. Proved by `pnpm spec:check` with no warnings.
- [ ] 6.3 At archive, bring the Purpose lines of the `configuration` and `plugin-system` specs, which a delta cannot reach, to `config.toml`.
