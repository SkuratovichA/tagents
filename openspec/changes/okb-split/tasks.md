## 1. Pull request A: the okb binary

- [x] 1.1 This change; `pnpm spec:check` exits 0
- [x] 1.2 Crate `crates/okb` with the moved knowledge module and its tests; `cargo test --workspace --locked`
- [x] 1.3 `index`, `search`, `show`, `list`, `lint`, `toc`, `usage` in okb at byte parity with the oracle; `bash tests/rust-knowledge-parity.sh`
- [x] 1.4 `packages/knowledge` deleted; `spec/cli/okb.json` and okb's texts; `pnpm -r build`, `pnpm -r typecheck`, `pnpm -r test`, `pnpm messages:check`, `pnpm plugin:check`
- [x] 1.5 `tagents-core knowledge` forwards; installer, wrappers and launcher move; `bash tests/install.sh`, `bash tests/knowledge-launcher.sh`
- [x] 1.6 okb archives in the release, version 0.8.0; `bash tests/release.sh`, `sh .github/scripts/core-release.sh gate origin/main`
- [x] 1.7 Docs and site name `okb`; `pnpm -r test`

## 2. Pull request B: the okb plugin

- [ ] 2.1 `plugins/okb` manifest, launcher `okb-mcp`, skill and generated references; marketplace lists it; `pnpm plugin:check`, CI `claude plugin validate --strict`
- [ ] 2.2 The generator keeps manifest, digest and version per plugin; `pnpm -r test` in `packages/contract`
- [ ] 2.3 `tagents` declares `"dependencies": ["okb"]`; `bash tests/knowledge-launcher.sh`
- [ ] 2.4 `sessions_recent` and `sessions_search` served by the `tagents` MCP server; `bash tests/rust-mcp-parity.sh`, `cargo test --workspace --locked`
- [ ] 2.5 okb's config directory, `OKB_DIR`, the copy of the usage store and the fallbacks; `bash tests/rust-knowledge-parity.sh`
- [ ] 2.6 `tagents-knowledge` as a shim that names `okb`; version 0.9.0; `bash tests/install.sh`, `sh .github/scripts/core-release.sh gate origin/main`
- [ ] 2.7 Archive the change
