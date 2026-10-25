# Demo recordings

The pictures in `docs/images/` come from a made-up machine, not from a real one: five chats in four projects on two accounts (`work`, `personal`), a few closed sessions, fake costs.

Run `docs/demo/record.sh` to regenerate all of them, or `docs/demo/record.sh hero timeline` for some (the names of the `.tape` files). Each recording builds the machine from scratch, records it with VHS and tears it down.

It needs `vhs` (with `ttyd` and `ffmpeg`), `tmux`, `jq` and the JetBrainsMono Nerd Font Mono. The list's footer needs fzf 0.63 or later: when the installed fzf is older, `record.sh` unpacks a newer one from the Homebrew bottle into `docs/demo/.cache` and uses it for the demo only. The first run lets VHS download its browser into the demo home.

The real `tagents` and the real hook run against a stand-in `claude` (`fake-claude.sh`) that sends the hook and status line events a chat would send. `env.sh` moves `HOME`, the tmux socket directory, `TA_STATE_DIR` and `TA_CONFIG` under `/tmp/tagents-demo`, so neither your tmux server nor your `~/.claude` is read or written. Logs of the last run are in `docs/demo/.cache/logs`.

The notification picture (`notify.png`) is not part of `record.sh`: it is three real macOS notices, posted with `tagents notify test` and captured window by window by `docs/demo/notify.sh`, so nothing else on screen ends up in it. It needs the notify plugin installed and allowed, Screen Recording allowed for the terminal, and ImageMagick; the script's header has the details.
