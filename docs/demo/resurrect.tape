# The tmux server dies, tmux starts again, `tagents --resurrect` brings every chat back with --resume and the dashboard with them.
Source "docs/demo/common.tape"
Output "docs/images/resurrect.gif"
Hide
Type "export PS1='$ ' TA_WIDTH=52; (docs/demo/world.sh dash-when-attached 0.6 &) >/dev/null 2>&1; clear; tmux attach -t storefront" Enter
Sleep 3.5s
Show
Sleep 2.5s
Ctrl+B
Type ":"
Type "kill-server" Enter
Sleep 1.5s
Type@25ms "# the server is gone, and the chats with it" Enter
Sleep 0.6s
Type@25ms "tmux new-session -d -s main" Enter
Sleep 0.8s
Type@25ms "tagents --resurrect" Enter
Sleep 4.5s
Type@25ms "tmux attach -t tagents" Enter
Sleep 4.5s
