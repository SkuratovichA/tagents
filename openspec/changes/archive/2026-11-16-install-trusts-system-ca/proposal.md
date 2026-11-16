## Why

Node trusts only the CA list it ships with. Behind a TLS proxy that re-signs traffic with a CA from the operating system's store, the build step of `install.sh` failed on every registry fetch with `UNABLE_TO_GET_ISSUER_CERT_LOCALLY` while curl worked, so `tagents update` printed `building`, then `the build of <commit> failed, the copy is back on <commit>`, and the machine never got the new version. The daily update LaunchAgent runs `install.sh` with only `TAGENTS_HOME` and `PATH` in its environment, so the fix has to live inside `install.sh`.

## What Changes

- `install.sh` adds `--use-system-ca` to `NODE_OPTIONS` before the default build, when the node on `PATH` accepts the flag (node 22.15 and newer).
- A `NODE_OPTIONS` that already holds the flag is left as it is, and a node that refuses the flag leaves `NODE_OPTIONS` untouched.
- An overridden build (`TAGENTS_BUILD_CMD`) brings its own toolchain: the installer starts no node for it and leaves its environment alone.

## Impact

- Specs: `claude-code-plugin` gets one ADDED requirement.
- Code: `install.sh` (`trust_system_ca`, called in `main` in the default build's branch, after `need_toolchain`).
- Tests: `tests/install.sh`, section 17.
- Docs: `CHANGELOG.md`.
