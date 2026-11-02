## Why

On tmux below 3.8 the viewport's client, a client inside a tmux pane, does not report the terminal feature `sync`, so each redraw reaches the outer terminal unwrapped and the cursor walks over the screen at every frame of an agent.

## What Changes

- The viewport's client is attached with `-T sync`.
- The Compatibility table of `README.md` says which tmux keeps the cursor steady.

## Impact

- Specs: `cockpit` gets one ADDED requirement after the viewport's terminal descriptor.
- Code: `lib/tagents/cockpit.sh`.
- Tests: `tests/cockpit.sh`.
