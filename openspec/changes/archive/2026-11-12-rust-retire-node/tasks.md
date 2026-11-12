## 1. The binary answers every call of its verbs

Pull request 1.

- [x] 1.1 `session`, `sessions` and `doctor` return `Output`; the usage words and the one `None` arm of the front door are in place (`git grep -n -E 'exec_node|None =>' crates/tagents-core/src/front_door.rs`)
- [x] 1.2 `parse_args.rs` is the one reader of command lines; `args.rs` is gone
- [x] 1.3 The classes handed to node are answered: texts and signal failures, working directory, references (`badRef`), environment and arguments read lossily, the plugin config and resolution
- [x] 1.4 `notify run` has no hand-over (`notify/hand_over.rs` is deleted)
- [x] 1.5 The parity suites say `rust` for every call of the verbs and `OWN_ERR` or `OWN_CODE` where the binary words a line or picks a code of its own; the vector generators and fixtures follow
- [x] 1.6 The delta specs, `docs/architecture/rust-core.md`, the changelog and the version

## 2. The oracle

- [x] 2.1 `tests/parity-oracle.sh` unpacks tag `v0.6.7` and builds it once; every suite reads node's side from there
- [x] 2.2 CI fetches the tag and runs the script; the vector generators and their CI steps go, the fixtures are frozen

## 3. The deletion

- [x] 3.1 `packages/mcp` goes whole
- [x] 3.2 The verbs of `packages/core/src/cli`, `serve` and `mcp` of `packages/knowledge`, and the code only `notify run` reaches in `packages/notify` go, with their tests
- [x] 3.3 Node's CLI answers a retired verb with the needs-binary line and exit 69; the wrappers, the installer and the launcher follow the design

## 4. Documents and archive

- [x] 4.1 `docs/architecture/rust-core.md` and the specs say what is true after the deletion
- [x] 4.2 The change is archived
