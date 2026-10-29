## 1. The CLI spec as data

- [x] 1.1 Put the verbs, flags, exit codes, summary keys and `impl` of every `tagents-core` command into `spec/cli/tagents-core.json` and describe it with `spec/cli/cli-spec.schema.json`, one optional string `effect` allowed (`cargo test -p tagents-spec`: `the_schema_and_the_model_name_the_same_keys`, `effect_is_optional_and_a_string`, `a_key_the_schema_does_not_name_is_refused`)
- [x] 1.2 Read the file from `packages/core/src/cli/spec.ts` with strict schemas, keeping `CommandSpec` and `CliContract` as they were, and keep `impl` and `effect` out of what `parseArgs` and the contract see (`pnpm --filter @tagents/core test`: `cli-spec.test.ts`, `the loader keeps impl and effect out of what parseArgs and the contract see`)
- [x] 1.3 Make the contract generator read the same file and prove that the generated contract did not move (`pnpm plugin:gen` then `git diff --exit-code`, and `pnpm plugin:check`)
- [x] 1.4 Pin that a verb is served by one program only (`cli-spec.test.ts`: `every verb says which program serves it, and a verb word is served by one program`)

## 2. The Rust front door

- [x] 2.1 Cargo workspace at the repository root with `tagents-spec` and `tagents-core`, `rust-toolchain.toml`, `target/` ignored, `unsafe_code` forbidden and `unwrap_used` and `expect_used` denied outside tests (`cargo clippy --workspace --all-targets -- -D warnings`)
- [x] 2.2 Serve the verbs the file marks `rust`, answer `--spec` with them, and exec the node CLI for every other word with the exit code untouched (`cargo test -p tagents-core --test front_door`: `spec_flag_prints_the_data_file_entries_of_the_verbs_it_serves`, `every_other_word_reaches_the_node_cli_with_argv_environment_and_stdin`, `the_exit_is_the_node_clis_even_when_it_is_a_signal`)
- [x] 2.3 Refuse the cases the node CLI cannot be run in, with the codes a shell uses (`front_door`: `a_missing_node_cli_is_exit_2_and_says_how_to_build_it`, `a_node_that_cannot_run_is_exit_127_or_126`, `node_is_looked_up_on_path_when_no_node_is_pinned`, `the_binary_finds_its_node_cli_through_a_symlink`)
- [x] 2.4 Leave SIGPIPE at its default for the node CLI and ignore a closed stdout like the node CLI does (`front_door`: `the_node_cli_starts_with_sigpipe_at_its_default`, `a_closed_stdout_is_not_an_error`)
- [x] 2.5 Pin the group invariant and the exit codes to the data file (`front_door`: `a_group_is_served_by_one_program_wholly`, `exit_codes_in_the_code_are_the_ones_the_data_file_names`)

## 3. The sessions verbs in Rust

- [x] 3.1 Port `packages/core/src/transcripts.ts` and `sessions()` of `main.ts`: `sessions recent [N]`, `search <words…>`, `show <id-prefix>`, bare `sessions`, the usage lines (`cargo test -p tagents-core`: the unit tests of `js`, `json`, `date`, `node`, `transcripts` and `sessions`)
- [x] 3.2 Reproduce the five recorded outputs from a Rust-seeded home (`front_door`: `sessions_print_the_bytes_the_node_cli_recorded`, `sessions_refusals_keep_the_node_cli_text_and_codes`)
- [x] 3.3 Run the node CLI and the Rust binary on the same seeded homes and compare stdout, stderr and the exit code byte for byte (`env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$(mktemp -d)" bash tests/rust-parity.sh`)
- [x] 3.4 Check the parity suite by mutating the port: each of 22 single edits makes the suite fail (`design.md`, the parity decision)

## 4. The seam in the shell

- [x] 4.1 `forward_core` runs `target/release/tagents-core` when it is an executable file, after `PATH` and before the built node CLI (`tests/dispatch.sh`: section 3)
- [x] 4.2 `install.sh` names the Rust binary in the `tagents-core` wrapper only when it is executable at install time, and with none the wrappers are byte for byte the old ones (`tests/install.sh`: section 13)
- [x] 4.3 Compare the wrappers an installer of `origin/main` and this installer write, with and without a pinned node, and with no binary (`diff -r` of two scratch directories, in the pull request)

## 5. CI and documents

- [x] 5.1 `.github/workflows/rust.yml`: `cargo fmt --check`, `clippy -D warnings`, `cargo test`, `pnpm build` and the parity suite, on changes to the Rust workspace, `spec/` and `packages/core/` (the workflow run of the pull request)
- [x] 5.2 One page under `docs/architecture/` describing the front door, the lookup order, the spec file and how to run the parity suite (`pnpm docs:build`)
- [x] 5.3 `pnpm spec:check` accepts this change
