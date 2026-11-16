#!/bin/sh
# The SessionStart hook of the tagents plugin (hooks/hooks.json): tells the session its own id and that it can tag itself, so the owner finds it by typing a tag into the dashboard's search. Silent outside a tmux pane (no dashboard row to tag) and outside the interactive CLI (a headless run is not reminded). Not a settings hook: those are registered from claude-settings.json, and install.sh wraps every hooks/*.sh as one, which is why this file lives in hooks/plugin/.
[ -n "${TMUX_PANE:-}" ] || exit 0
[ "${CLAUDE_CODE_ENTRYPOINT:-cli}" = cli ] || exit 0
sid=$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"\\]*\)".*/\1/p' | head -n 1)
[ -n "$sid" ] || exit 0
printf '%s\n' "tagents: this session's id is $sid. Tag it with the tagents plugin's tool tagents_tags_add (k: that id, tags: words separated by spaces, such as a ticket key, the repository or a topic) as soon as you know what the session is about, and again when the work moves on, so the owner can find it by typing a tag into the dashboard's search. A session keeps at most 10 tags: tagents_tags reads them and tagents_tags_set replaces the list."
