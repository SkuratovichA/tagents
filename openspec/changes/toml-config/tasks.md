## 1. The dashboard reads TOML

- [x] 1.1 Add `cfg_parse_toml` to `lib/tagents/config.sh`: the TOML subset flattened into `path<TAB>value` lines, every construct outside it refused per line with `file:line`. Proved by `tests/config-toml.sh`.
- [x] 1.2 Choose the file in `cfg_resolve`: `$TA_CONFIG` verbatim, else `config.toml`. Proved by `tests/config-toml.sh` and `tests/config.sh`.
- [x] 1.3 Read the per-machine overlay `config.<host>.toml`, whole `a.b` subtrees replaced. Proved by `tests/config.sh` and `tests/config-toml.sh`.
- [x] 1.4 Make the refresher and `lib/tagents/accounts.sh` follow `config*.toml`. Proved by `tests/refresh.sh` and `tests/forks.sh`.

## 2. The TypeScript programs read TOML

- [x] 2.1 `packages/core/src/config-file.ts`: the config file in use and its parser. Proved by `packages/core/test/config-file.test.ts`.
- [x] 2.2 The plugin host, `plugin list` and `plugin add|remove` use it, with `plugin add` creating `config.toml` and editing it as text. Proved by `packages/core/test/plugin-host.test.ts` and `plugin-cli.test.ts`.
- [x] 2.3 Read plugin option files from `<name>.toml`. Proved by `packages/core/test/plugin-options.test.ts`.
- [x] 2.4 Read `knowledge.dir` from `config.toml` and show the snippet as a `[knowledge]` table. Proved by `packages/knowledge/test/config.test.ts`.
- [x] 2.5 Make the notify service reload when `notify.toml` changes. Proved by `packages/notify/test/service.test.ts` and `commands.test.ts`.
- [x] 2.6 List the verbs without `config convert`. Proved by `packages/core/test/cli-spec.test.ts`, `plugin-commands.test.ts` and `pnpm plugin:check`.

## 3. The schema

- [x] 3.1 Write `schemas/config.schema.json` and `config.example.toml`. Proved by `packages/core/test/config-schema.test.ts`.
- [x] 3.2 Pin the schema to the keys the dashboard reads and to the zod schemas of the TypeScript readers. Proved by `packages/core/test/config-schema.test.ts` and `packages/knowledge/test/config-schema.test.ts`.
- [x] 3.3 Lint the example with the schema in taplo when `taplo` is on PATH.

## 4. The existing suites

- [x] 4.1 Write the config of every shell suite as TOML. Proved by running `tests/*.sh`.

## 5. YAML is dropped

- [x] 5.1 Remove the YAML parser, the deprecation notices, the twin logic and `tagents config convert`, and the `yaml` dependency of `@tagents/core`.
- [x] 5.2 Remove the YAML fixtures and tests; add the cases that a lone `config.yaml`, `<name>.yaml` and `config.<host>.yaml` are not looked at.

## 6. Docs and specs

- [x] 6.1 Bring the README, `docs/`, the package READMEs, the skill text, the installer and the header comments to `config.toml`.
- [x] 6.2 Write the deltas in this change. Proved by `pnpm spec:check` with no warnings.
- [ ] 6.3 At archive, bring the Purpose lines of the `configuration` and `plugin-system` specs, which a delta cannot reach, to `config.toml`.
