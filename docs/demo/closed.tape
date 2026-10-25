# ctrl-y lists the chats that are closed, with what each cost, and resumes the one you pick.
Source "docs/demo/common.tape"
Output "docs/demo/.closed.gif"
Hide
Type "export PS1='$ ' TA_WIDTH=52; (docs/demo/world.sh sidebar-when-attached 0.6 &) >/dev/null 2>&1; clear; tmux attach -t storefront" Enter
Sleep 3.5s
Show
Ctrl+Y
Sleep 2s
Down 1
Sleep 1.5s
Screenshot "docs/images/closed.png"
Sleep 0.5s
