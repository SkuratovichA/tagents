# The tmux status bar with the one-line tally from `tagents --counts`.
Source "docs/demo/common.tape"
Set Height 300
Output "docs/demo/.statusbar.gif"
Hide
Type "export PS1='$ '; (docs/demo/world.sh statusbar-when-attached 0.5 &) >/dev/null 2>&1; clear; tmux attach -t storefront" Enter
Sleep 4s
Show
Sleep 1s
Screenshot "docs/images/statusbar.png"
Sleep 0.3s
