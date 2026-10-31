# tagents

This repository keeps no `claude-changelog/` and no dated log of work, and `CHANGELOG.md` lists what each release of `tagents-core` contains and what `main` holds beyond the last one: what tagents does is specified under `openspec/specs/`, one capability per spec, and a change is proposed, applied and archived with OpenSpec (the "Specs" section of `docs/development.md`). Its history is git's.

`LEARNING.md` stays: read it before a change, and add to it when a mistake was made and then fixed.

Every shell suite under `tests/` runs on a scratch tmux server, one at a time, as `env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$(mktemp -d)" bash tests/<suite>.sh`; `tests/scratch-guard.sh` refuses anything else.
