## Context

`install.sh` is both the first install and the update: `tagents update` and the daily LaunchAgent run the `install.sh` of the managed copy, which fetches, moves the copy with `git checkout --detach`, builds, and writes the wrappers. The whole program is one function called on the last line, so the checkout that rewrites the file under the running shell cannot make it execute the new file's bytes at an old offset (`LEARNING.md`, 20.10.2026). The price of that protection is that everything after the checkout is still the program of the commit the copy left: on 23.10.2026 the update from d3530b7 to e4639fc, which brought the node pin, wrote the wrappers in the old `exec node` form, and only the next update pinned them.

## Goals / Non-Goals

**Goals:**

- The update that brings a change to `install.sh` is finished by that `install.sh`: its build, its return to the old commit when the build fails, and the commands, hooks and LaunchAgent it writes.
- The protection against a file rewritten under the running shell stays as it is.
- An update to a commit whose `install.sh` cannot take the hand-over still completes.

**Non-Goals:**

- A first install that clones the copy itself: the dotfiles bootstrap and the README clone the copy and then run its own `install.sh`, so their installer is already the copy's.
- A copy that moved but was never built: the build still runs only after a move, after a clone, or when `packages/core/dist/cli/main.js` is missing.
- The machine on a commit from before this change: its first update to this change still runs its old installer.

## Decisions

**Hand the rest of the run over with `exec`, right after the move.** Once `git checkout --detach "$target"` succeeds and the copy has moved, the running installer execs `sh "$TAGENTS_HOME/install.sh"` with its own arguments. `exec` keeps the pid, stdout, stderr and environment, and nothing of the old program runs after it.

```sh
TAGENTS_MOVED_FROM=$prev; export TAGENTS_MOVED_FROM
exec sh "$TAGENTS_HOME/install.sh" "$@"
```

Rejected: running the new installer as a child and exiting with its status leaves two processes holding one lock and the old program alive around the new one; having `tagents update` move the copy itself and then run `install.sh` would leave the LaunchAgent and a direct `sh install.sh` on the old behaviour and put update logic in the dashboard script.

**The commit moved from travels in `TAGENTS_MOVED_FROM`.** The run handed over needs it for two things: to know that it has to build although the copy already stands on the target, and to know where to go back when the build fails. Given the variable, it skips the fetch, the `--check` report and the move, reads the target from `HEAD`, and unsets the variable so the build does not inherit it. Rejected: a `--moved-from` option, which would be a public flag that `--help` lists and that every caller could pass, for something only `install.sh` sets.

**Hand over only to an installer that takes it.** Before the `exec`, `grep -q TAGENTS_MOVED_FROM "$TAGENTS_HOME/install.sh"` decides. An installer from before this change, reached by a revert or by `TAGENTS_REF` naming an old branch, would find its own pid in the lock and stop with "another install is running", or, without the lock, see the copy up to date and skip the build; the running installer finishes those updates in-process, as every update did until now.

**The lock outlives the `exec`.** The lock directory holds the pid that took it, and `exec` keeps the pid while it drops the `EXIT` trap that removes the lock. `acquire_lock` treats a lock holding its own pid as its own: it skips the liveness check, writes the pid again and sets the traps again, so the run handed over removes the lock when it ends. Rejected: releasing the lock before the `exec` and taking it again after, which leaves a window for the LaunchAgent's run to start a second update.

**Option parsing moves into `parse_args`.** `main` passes its arguments to the next installer unchanged, so the `shift`s happen in a function of their own, whose positional parameters are its own, and `--help` exits from there.

**A clone is not handed over.** A fresh clone stands on origin's default branch, and an update that fails to build after a clone has no installed commit to go back to; the clone path keeps its behaviour.

## Risks / Trade-offs

- [A machine on a commit from before this change runs its old installer on the first update to it] → From the next update on, the installer that moves the copy is a new one and hands over. The pull request says so, and the daily LaunchAgent makes that next update without anybody.
- [The target's `install.sh` fails before `main` runs, for example on a syntax error] → The copy has moved and is not built, and the lock holds a dead pid, which the next run takes over. `tests/install.sh` now runs the tree's `install.sh` as the copy's on every update case, so such a file fails the suite before it reaches main.
- [Running a development checkout's `install.sh` against the managed copy no longer finishes with that checkout's program once the copy moves] → An installer change is tried live with `TAGENTS_REF=<branch> tagents update`, whose run hands over to the branch's installer.
- [A future `install.sh` names `TAGENTS_MOVED_FROM` without honouring it] → The variable is the protocol: an installer that drops the hand-over drops the name with it.

## Migration Plan

After the merge, `tagents update` moves the live copy with the installer it stands on, which predates the hand-over; the wrappers it writes are the same as the new installer's, so nothing waits for a second run. Every later update is handed over. Rollback is a revert: the update to the revert commit is finished by the running installer, because the reverted `install.sh` no longer names `TAGENTS_MOVED_FROM`.

## Open Questions

None.
