## Context

The knowledge module of `tagents-core` shares its plumbing with the other verbs: the JavaScript-compatible helpers (`js`, `json`, `node`, `date`), the signal handling (`ending`), the file watch and lock (`watch`, `sync`), the MCP server loop (`mcp::server`, `mcp::run`), the exit codes (`sessions::exit`) and, for two tools, the session transcripts. The seven CLI verbs live in `packages/knowledge` and are the only user of `node:sqlite` there.

## Decisions

- `okb` depends on `tagents-core` as a library and the needed items become `pub`; no plumbing crate is extracted, because a second move of the same code would double the diff for no behaviour. The dependency runs one way: `tagents-core` never names `okb`.
- The seven verbs are ported by reading the node source and comparing bytes with the node program of an oracle tag. `tests/rust-knowledge-parity.sh` gains command-line scenarios, flags and error paths included; usage text, stderr lines and exit codes are part of the comparison.
- The contract package stops importing the node source. The CLI description becomes `spec/cli/okb.json`, printed by `okb --spec` and compared by a test, the pattern of `spec/cli/tagents-core.json`. The user-visible texts of okb live in a JSON the binary embeds, like `spec/cli/messages.json`.
- `tagents-core knowledge` stays as a front door verb only to forward, because the plugin of every installed copy calls `tagents-knowledge`, and people type `tagents-core knowledge`. It never reaches node.
- The wrapper `tagents-knowledge` and the new `okb` wrapper are installed like the other wrappers. The `okb` wrapper prints the needs-binary line and exits 69 with no binary, so the launcher's fallbacks end as before.
- Release: `okb-<version>-<triple>.tar.gz` and `.sha256` hold exactly `okb` and `LICENSE`, for the same three targets; the release has twelve files. The release gate counts `crates/*/src/*`, so it already covers the new crate.
- Pull request B: the plugin `okb` is a second directory under `plugins/`, the dependency is the bare name `okb` so no plugin tags are needed, and the generator becomes multi-plugin. `sessions_*` tools are not derived from a CLI verb, so the `tagents` server gets a short list of hand-declared tools. Config and state names are in the `knowledge` and `configuration` deltas.

## Risks

- Byte parity of the ported verbs depends on the oracle tag; if the tag answers differently from main's node, the suite pins the tag that matches and says so.
- Old plugin copies call `tagents-knowledge join`; the wrapper keeps that working until the plugin updates.
- The usage store is the only record of reads; B copies it and never deletes the old file.
