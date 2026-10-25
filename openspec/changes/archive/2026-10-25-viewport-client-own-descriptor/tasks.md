## 1. Viewport

- [x] 1.1 `viewport` in `lib/tagents/cockpit.sh` attaches with `0<>"$tty" 1>&0 2>&0`
- [x] 1.2 `tests/cockpit.sh` checks that the server's descriptors on the viewport's tty are still writable and non-blocking after the list is brought back; it fails without 1.1
- [x] 1.3 Section 17b of `tests/resurrect.sh` runs to the end

## 2. Suites

- [x] 2.1 `scratch_guard` exports `TA_SUITE_RUN` and starts the reaper outside the suite's jobs and process group
- [x] 2.2 A suite killed with `kill -9` leaves no tmux process behind

## 3. Notes

- [x] 3.1 `LEARNING.md` has one entry for the deadlock and one for the leak
