# tagents --timeline: the last 24 hours as bars, one row per chat.
Source "docs/demo/common.tape"
Set Height 470
Output "docs/demo/.timeline.gif"
Hide
Type "export PS1='$ ' COLUMNS; clear" Enter
Sleep 0.5s
Show
Type "tagents --timeline" Enter
Sleep 2s
Screenshot "docs/images/timeline.png"
Sleep 0.5s
