# The money shot: the sidebar list, one chat flips to BLOCKED, enter moves the sidebar into its window, ? shows the keys.
Source "docs/demo/common.tape"
Output "docs/images/hero.gif"

Hide
Type "export TA_WIDTH=52; clear" Enter
Type "(docs/demo/world.sh sidebar-when-attached 0.6 &) >/dev/null 2>&1" Enter
Type "tmux attach -t storefront" Enter
Sleep 3s
Show
Sleep 2.5s
# the api chat asks for permission (ctrl-g is a tmux root binding the demo world sets)
Ctrl+G
Sleep 2s
Down 8
Sleep 1s
Enter
Sleep 3s
# back to the sidebar with the tmux prefix, then the keys window
Ctrl+B
Left
Sleep 0.8s
Type "?"
Sleep 3s
Escape
Sleep 1.5s
