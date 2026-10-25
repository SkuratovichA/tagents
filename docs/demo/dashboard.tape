# A still of the list at its best: the sidebar zoomed over the whole window so every column has room.
Source "docs/demo/common.tape"
Set Height 430
Output "docs/demo/.dashboard.gif"
Hide
Type "export PS1='$ ' TA_WIDTH=52; (docs/demo/world.sh sidebar-when-attached 0.6 &) >/dev/null 2>&1; clear; tmux attach -t storefront" Enter
Sleep 3.5s
Ctrl+B
Type "z"
Sleep 2s
Down 3
Show
Sleep 1s
Screenshot "docs/images/dashboard.png"
Sleep 0.3s
