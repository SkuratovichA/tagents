---
id: tmux-cheatsheet
title: tmux keys worth remembering
kind: cheatsheet
tags: [tmux, cli]
updated: 2026-09-09
scope: global
---

A short list, kept short on purpose. A rollback of a bad pane layout is
`prefix + :kill-session`, which is why that word shows up here too.

## Panes

`prefix + %` splits vertically, `prefix + "` horizontally, `prefix + z` zooms
one pane to the whole window.

## Sessions

`tmux ls` lists them, `tmux attach -t name` joins one, `prefix + d` detaches
without stopping anything that runs inside.
