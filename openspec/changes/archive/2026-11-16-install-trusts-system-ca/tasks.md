## 1. The default build trusts the system CA store

- [x] 1.1 Write failing checks in `tests/install.sh`, section 17, with a fake node and a fake pnpm on `PATH`: the default build with `NODE_OPTIONS` unset, set to another option, and already holding the flag, a fake node that refuses the flag, and an overridden build that must start no node. Proof: the suite run with the call removed from `install.sh` fails the first two checks, with the `case` guard removed fails the third, and with the call outside the default-build condition fails the overridden-build checks.
- [x] 1.2 Add `trust_system_ca` after `need_toolchain` in `install.sh`, call it right after `need_toolchain` in the default-build condition, and name the behaviour in the header's environment table. Proof: `tests/install.sh` passes with no failure and `sh -n install.sh` exits 0.
- [x] 1.3 Keep the `CHANGELOG.md` line true. Proof: `pnpm spec:check`.
