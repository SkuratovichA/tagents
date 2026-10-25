# ctrl-n on a row starts a new chat in that project, on the account the config rules pick for it.
Source "docs/demo/common.tape"
Output "docs/images/new-chat.gif"
Hide
Type "export PS1='$ ' TA_WIDTH=52; (docs/demo/world.sh sidebar-when-attached 0.6 &) >/dev/null 2>&1; clear; tmux attach -t storefront" Enter
Sleep 3.5s
Show
Sleep 2s
Down 5
Sleep 1.5s
Ctrl+N
Sleep 5s
