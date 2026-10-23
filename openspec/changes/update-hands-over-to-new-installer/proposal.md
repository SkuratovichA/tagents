## Why

On 23.10.2026 the first `tagents update` after the node pin was merged left `tagents-core` and `tagents-knowledge` in the old `exec node` form, and only a second update pinned them. `sh` parses `install.sh` whole before it runs a line, so the run that moves the copy to a new commit goes on with the program of the commit it moved from: every change to `install.sh` took effect one update late, and the update that brought the pin could not pin.

## What Changes

- An update that moves the managed copy hands the rest of its run (the build, the return to the old commit when the build fails, and the commands, hooks and LaunchAgent) to the `install.sh` the copy now holds, with the same arguments and with `TAGENTS_MOVED_FROM` naming the commit it moved from.
- The run handed over keeps the lock the first one took, does not fetch or move again, and builds the copy.
- A commit whose `install.sh` does not take `TAGENTS_MOVED_FROM`, one from before this change, is finished by the running installer, as every update was until now.
- A first install that clones the copy itself still runs to the end in the installer that started it. The dotfiles bootstrap and the README clone the copy first and run its own `install.sh`, so nothing lags there.
- `LEARNING.md` records the one-update lag and how it was found.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `claude-code-plugin`: an update is finished by the installer of the commit it moves the copy to.

## Impact

- `install.sh`: option parsing, the lock, the move, the header comment and the environment list.
- `tests/install.sh`: the test origin carries the tree's `install.sh`, so every update case goes through the hand-over; new cases for one update installing with the new installer and for a target installer that does not take the hand-over; `HOME` is the sandbox's, since the arguments now cross an `exec`.
- `LEARNING.md`.
- The live install: a machine on a commit from before this change runs its old installer on the first update to it, so the new installer takes over from the update after that, by hand or from the daily LaunchAgent run.
