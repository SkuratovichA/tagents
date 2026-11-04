## Why

An agent renaming itself with `tagents --label "$TMUX_PANE" NAME` stored the name under its pane while its session could already have a label. The row and the dialogs read the session's label first, so the window took the new name and the row and the `ctrl-r` dialog stayed on the older one. With no older label the row showed the new name, and the dialog, which asked for the session's key alone, opened on the pane title. A label left under the pane also came back as the name when the session's label was cleared, where the requirement promises the title.

## What Changes

- A name given for a pane whose record names a session is stored for that session, by `--label` and by `ctrl-r` alike, and the pane's own line goes with it.
- An answer removes the label of both keys of the agent, so clearing a name goes back to the title.
- The rename, kill and resume dialogs and the preview heading read the session's label, then the pane's, the order the row and the window sweep already use.

## Impact

- Specs: `dashboard-keys` gets one MODIFIED and one ADDED requirement, and `window-names` one MODIFIED requirement.
- Code: `lib/tagents/names.sh`, `lib/tagents/actions.sh`, `lib/tagents/launch.sh`, `lib/tagents/preview.sh`.
- Tests: `tests/names.sh`.
