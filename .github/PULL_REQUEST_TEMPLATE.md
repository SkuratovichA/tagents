## What and why

## How it was tested

Which suites you ran (`pnpm test`, `bash tests/<suite>.sh`, `cargo test --workspace`, the parity suites).

## Checklist

- [ ] A change in behaviour has an OpenSpec change under `openspec/changes/<id>/`, and `pnpm spec:check` passes.
- [ ] `pnpm plugin:gen` is run when the contract moves, and `pnpm plugin:check` passes.
- [ ] The workspace version in `Cargo.toml` is raised when an input of the `tagents-core` binary changes.
- [ ] The documentation under `docs/` and the README say what is true after this change.
