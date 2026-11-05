## Why

With a dashboard of many agents the person loses the one they are in. Nothing on the list marks the session on screen: the red pointer is fzf's cursor and goes wherever they browse. Rows are also sorted by the time they last typed into each, so the list jumps and the place of an agent cannot be learned.

## What Changes

- The row of the window on screen carries a `▸` in the slot of the tree's dash and is drawn bold. The mark follows the viewport.
- `ctrl-o` (verb `order`, `keys.order` in the config) switches the rows of a group to the order of their tmux window numbers, and back. The default stays the last message.

## Impact

- Specs: `dashboard-list` gets two ADDED requirements and one MODIFIED, `dashboard-keys` three MODIFIED, `dashboard-popup` one MODIFIED.
- Code: `lib/tagents/state.sh`, `lib/tagents/list.sh`, `lib/tagents/follow.sh`, `lib/tagents/refresh.sh`, `lib/tagents/keys.sh`, `lib/tagents/dash.sh`, `tagents`.
- Config: `keys.order`, in the schema and in `config.example.toml`.
