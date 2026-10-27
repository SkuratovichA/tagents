# The money shot: the dashboard, ? shows the keys, one chat flips to BLOCKED, enter shows it in the viewport.
Source "docs/demo/common.tape"
Output "docs/images/hero.gif"

Hide
Type "export TA_WIDTH=52; clear" Enter
Type "(docs/demo/world.sh dash-when-attached 0.6 &) >/dev/null 2>&1" Enter
# the api chat asks for permission 9s after the attach: every key typed in the list reaches the list, so no key can be the trigger
Type "((sleep 9; docs/demo/world.sh ctl api permit 'pnpm test --filter api') &) >/dev/null 2>&1; tmux attach -t storefront" Enter
Sleep 3s
Show
Sleep 2s
Type "?"
Sleep 3s
Escape
Sleep 3.5s
Down 8
Sleep 1s
Enter
Sleep 3.5s
