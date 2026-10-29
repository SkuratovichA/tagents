# Keys

Every key in the dashboard can be moved to another, so this site does not print a table of defaults that would go stale. The dashboard itself always knows where each key ended up, and this page shows you how to ask it.

## Finding the key you want

- **`?` in the list** opens every key in a window of its own, and `enter` runs the one you pick. It acts on the row the cursor was on, so it is a way to *use* a key you half-remember, not a printed list.
- **`tagents --keys`** prints where each key ended up, after your config has been applied.

The header above the list is one line: `enter · ? keys · ctrl-q quit`. Everything else is behind `?`. The direct keys still all work.

::: tip The cost of `?`
`?` is a printable character, so one thing it costs is typing a `?` into the filter query. `ctrl-w` (show or hide columns) costs the other: that was fzf's delete-the-word-before-the-cursor in the query. Those two keys are the whole bill, and the query is a project name long.
:::

## Moving a key

A `[keys]` table in `~/.config/tagents/config.toml` maps a verb to a key. Anything you do not name keeps its default.

```toml
[keys]
closed = "ctrl-y"
send = "alt-s"
```

[`config.example.toml`](https://github.com/SkuratovichA/tagents/blob/main/config.example.toml) lists every verb with its default beside it. The names are the verbs of the list: open, beside, new, pick, shell, goto, send, rename, undock, kill, tree, preview, refresh, columns, usage, closed, keys and quit. An entry for any other verb is ignored.

### Which names work

fzf's key names are what count:

- `ctrl-a` to `ctrl-z`
- `alt-a` to `alt-z`, and `alt-0` to `alt-9`
- `f1` to `f12`
- `enter`, `tab`, `btab`, `space`, `bspace`, `del`, `esc`
- the arrows (`up`, `down`, `left`, `right`), `home`, `end`, `pgup`, `pgdn`
- any single printable character

### What is refused

A name fzf does not know would stop it starting, so it is refused with a message and the default is kept. So is a key another verb already has.

```
keys.new: 'ctrl-1' is not a key fzf knows — using ctrl-n
```

`tagents --check` lists these problems along with the rest of the config's, and `tagents --keys` shows what is in force.

## In passing

Elsewhere in these docs, a default key is mentioned only in passing (`ctrl-y` for closed sessions, say). If you moved it, the page's meaning still holds; ask `?` for the key that is yours now.
