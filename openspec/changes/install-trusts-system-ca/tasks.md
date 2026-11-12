## 1. The build trusts the system CA store

- [x] 1.1 Write failing checks in `tests/install.sh`, section 17: a fake node that accepts the flag with `NODE_OPTIONS` unset, set to another option, and already holding the flag, a fake node that refuses it, and no node on `PATH`. Proof: the suite run with the call removed from `install.sh` fails exactly the first three checks.
- [x] 1.2 Add `trust_system_ca` after `need_toolchain` in `install.sh`, call it before `say "building"`, and name the behaviour in the header's environment table. Proof: `tests/install.sh` passes with no failure and `sh -n install.sh` exits 0.
- [x] 1.3 Add the `CHANGELOG.md` line. Proof: `pnpm spec:check`.
