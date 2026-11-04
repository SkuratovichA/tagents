## Why

The Rust binary serves `session`, `sessions`, `doctor` and `plugin add`, `remove` and `new`, and `notify run`, but each of them still hands some calls to the node CLI: a call the binary could not prove it answers as node does, a reference it cannot hold, a failed start. While one such path exists, node's implementation of those verbs cannot be deleted, because the person would get "unknown command" where they got an answer. Stage S5 of the port (issue #28) retires node's implementation of the verbs the binary serves. This change is the first step: the binary answers every call of its verbs, so the step after it can delete node's code.

## What Changes

- No call of a verb with `impl: "rust"` reaches node. `session`, `sessions` and `doctor` return an output, never "not mine"; `plugin` reaches node only for `plugin list`, a bare `plugin` and a word it does not know.
- What node's answer was the reason for handing over is printed by the binary in this order of preference: node's own bytes for a line of the messages table or a fixed template (the `parseArgs` errors); node's frame and exit code with the words of the Rust parser inside for a third party's text (the TOML parser); `badRef` with exit 1 for a reference the binary cannot hold or act on.
- An argument or an environment entry that is not UTF-8 is decoded lossily, as node decodes it. An ignored SIGCHLD at the start of `session prompt` does not stop the verb.
- `tagents-core` with no word prints the usage line and exits 2; `help`, `--help` and `-h` print it and exit 0.
- `notify run` has no hand-over: a step before `started` that fails writes its line and exits 1, the code launchd retries.
- One reader of command lines: `parse_args.rs` replaces the grammar that returned "not mine" for a call it did not read.
- The parity suites flip every scenario marked `node` to `rust` except the calls that really are node's. A scenario whose words cannot match says what the binary prints instead (`OWN_ERR`, and `OWN_CODE` when the exit code differs too), and each is listed in "Where the two are known to differ" of `docs/architecture/rust-core.md`.
- The workspace version is raised.

Node is not edited in this change. The oracle (the suites keep comparing with node at a fixed tag), the deletion of node's verbs, the needs-binary line, the installer and the launcher are the later pull requests of the same change, described in `design.md`.

## Capabilities

### Modified Capabilities

- `core-front-door`: the binary answers every call of a verb marked `rust`, and the usage words.
- `rust-session`: a session call with an unknown or missing verb, an argument the node parser rejects, an argument or environment entry that is not UTF-8 and a reference the binary cannot hold are answered by the binary.
- `rust-plugin-verbs`: the config problems, the arguments and the resolution that went to node are answered by the binary.
- `rust-notify`: a start that fails is logged and exits 1.
