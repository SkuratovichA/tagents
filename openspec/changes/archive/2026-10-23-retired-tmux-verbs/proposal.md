## Why

The seat model was removed together with `--poke`, `--unpark`, `--undock-pane` and `--undock-window`. Its focus hooks call the first two, and the kill bindings its README handed out call the other two. An update lands under a running list, and those hooks stay in tmux until the first start of the new version removes them. Until then every focus on a docked chat or a placeholder ran the new script with a verb it no longer knew, and tmux showed `'…/tagents' --poke '%67'' returned 2` on the status line.

## What Changes

- `--poke`, `--unpark`, `--undock-pane` and `--undock-window` exit 0, print nothing and change nothing, instead of being unknown options.

## Impact

- Affected specs: `cli-dispatch`.
- Affected code: `tagents` (dispatch and the manual), `tests/dispatch.sh`, `README.md`, `skills/tagents/references/scripts.md`.
