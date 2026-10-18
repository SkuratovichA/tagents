# @tagents/notify

Desktop notifications for tagents: a banner when an agent needs you, and a click that docks that chat.

It watches the agents' event stream and posts one notice when something wants your attention. The kinds are `question` (AskUserQuestion, plan approval, MCP elicitation), `permission` (a permission prompt), `turn_done` (the answer is ready, your move), `cache_expiring` (the prompt cache is about to run out) and `session_end`. The first four are on by default; `session_end` is off.

Notices come only from agents, meaning a Claude session in a tmux pane of its own. Three kinds of session never post one, and no option turns them on: an Agent-tool subagent (its SubagentStop and its own Stop post nothing; a question or a permission prompt it raises blocks the agent that started it, so that one is posted as the agent's), a child session (a `claude -p` an agent started from its Bash tool, which the dashboard draws under that agent), and a headless session with no pane at all (a daemon's `claude -p` turn, which reports wherever it was started from and would leave a click nothing to dock). The hook files the last two under `s-<session id>`, and every event with such a key is left alone.

Each session has one notice at a time: a later notice replaces the earlier one instead of stacking, and a notice that is no longer true is withdrawn.

The engine only knows a `Notifier`. What posts the banner is the platform layer under `src/platform/`, and macOS is the one backend today.

## Install

```sh
tagents notify install
```

On macOS this builds the helper app if it is stale, asks for permission, then writes and starts a LaunchAgent that runs the engine in the background. Allowing notifications:

1. `tagents notify install` makes macOS ask whether "tagents" may send notifications: Allow.
2. If the prompt was missed: System Settings → Notifications → tagents → Allow notifications.
3. Alert Style, in System Settings → Notifications → tagents: "Persistent" keeps a notice on screen until you dismiss it, "Temporary" lets it disappear on its own (before macOS 26 they were called "Alerts" and "Banners").
4. Focus and Do Not Disturb hide banners; the notices still land in Notification Center.
5. `tagents notify status` must say `permission: authorized`.

macOS leaves the choice of Alert Style to the person. When it is Temporary (called Banners before macOS 26), `install` and `status` print a hint naming the setting, with a link that opens it: `open "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=io.github.skuratovicha.tagents-notify"`. When it is off, the hint says that nothing is shown on screen at all. Nothing is printed when it is Persistent. The hint appears only once the permission is `authorized`: before that, the permission line is what to fix.

macOS may announce a new background item in System Settings → General → Login Items & Extensions; it must stay allowed or launchd will not start the service.

Elsewhere `install` refuses with "no notification backend for <os> yet" and exits 2.

## Configuration

`<configDir>/plugins/notify.yaml`. Every key is optional; these are the defaults:

```yaml
backend: auto      # auto | macos | log | none — auto: macos on darwin, none elsewhere
click: dock        # dock: like Enter in the list · goto: the agent's own window · focus: terminal only
# icon: ~/pics/tagents.png   # a PNG for the notices' icon, unset by default; see below
events:
  question:       { enabled: true,  skip_visible: true }   # AskUserQuestion, plan approval, MCP elicitation
  permission:     { enabled: true,  skip_visible: true }   # a permission prompt
  turn_done:      { enabled: true,  skip_visible: true }   # the answer is ready, your move
  cache_expiring: { enabled: true,  skip_visible: false, after: 50m, ttl: 60m }
  session_end:    { enabled: false, skip_visible: true }
```

Durations are `<n>s|m|h`, combined like `1h30m`, or a bare number of seconds, and `after` must be below `ttl`.

`skip_visible`: when the agent's tmux pane is in some client's current window and that terminal is the frontmost app, the notice is dropped.

`icon` is an absolute path, a `~/` path, or a path relative to the directory of the options file. Unset, the icon is `notify-icon.png` next to the helper app (`~/Library/Application Support/tagents/`, or next to `TA_NOTIFY_APP`) when that file exists, and the app has no icon of its own otherwise. The icon is part of the helper app, so run `tagents notify install` after changing it: `install` rebuilds an app that is stale and prints `icon: <path>` or `icon: none`, as `status` does. An `icon` that names no file is a problem line in both, and the app is built without it.

An invalid file is logged once per problem and the engine runs on the defaults; `tagents notify status` prints the problems. The file is reloaded when it changes, so there is nothing to restart. What is watched is the real path of the `plugins` directory, filtered on the name `notify.yaml`: a config directory that is a symlink, such as `~/.config/tagents` pointing into a dotfiles repository, works in full. A `notify.yaml` that is itself a symlink is seen only when the link is replaced, not when its target is edited.

## Clicking a notice

`click: dock` runs `tagents --act open <pane> live <sid> <cwd>`, the same as Enter in the dashboard list. The `tagents` it runs is the first one on the PATH of the shell that ran `install` (the one your dashboard runs, a symlink stays the symlink), else the checkout's own, and `TA_NOTIFY_TAGENTS` overrides both: tagents re-points the global tmux focus hooks at whichever script ran, so a click running another one would move them away from the dashboard's. `click: goto` runs `tagents --goto <pane>`. `click: focus`, or a session with no pane, only raises the terminal.

## Commands

| | |
| --- | --- |
| `tagents notify run` | the engine in the foreground until SIGTERM, SIGINT or SIGHUP (a closed terminal); this is what the LaunchAgent runs. Exit 0 when it deliberately does not run (another service holds the lock, backend `none`, an unsupported OS) and when a signal stops it; exit 1 when it fails to start, which launchd retries at most every 5 minutes |
| `tagents notify install` | on macOS: build the app if stale, ask for permission, write and bootstrap the LaunchAgent, wait up to 5 s for it to run and the stream to be on, print the status and the steps; exit 1, naming the cause, when the permission is not `authorized`, the options file is invalid, or the service is not running (and the pid that holds the lock in its place, if there is one) |
| `tagents notify uninstall [--purge]` | boot the service out, delete the plist, switch the event stream off unless a `tagents notify run` in a terminal still holds the lock; `--purge` deletes the app too |
| `tagents notify status` | platform, backend, app (up to date, stale or missing), icon, permission and alert style, the script a click runs (ok or missing; with `click: focus` it says the script is not used), LaunchAgent (installed, running, pid), stream on or off, the options file and its problems, the service's memory |
| `tagents notify test [--kind <kind>]` | post one sample notice now through the platform notifier; a click docks `$TMUX_PANE` when it is set |

## Troubleshooting

`tagents notify status` says what is wrong with the setup: the permission, the alert style, the script a click runs, the service and the options file.

To see what a click did, read the helper's log. Use the full path, because zsh has a `log` builtin that shadows the tool:

```sh
/usr/bin/log show --last 10m --predicate 'subsystem == "io.github.skuratovicha.tagents-notify"'
```

Each click shows the command it ran, the app it raised, the child's exit status and, when there is one, the child's stderr.

After the icon changes, Notification Center may keep showing the old one. `killall NotificationCenter` clears it; it restarts on its own, and notices already delivered stay.

## Resources

No polling. One `fs.watch` on the state directory, one on the options directory, and at most two timers: the cache deadline's, which exists only while a deadline is armed and sleeps 5 minutes at most, and the follower's re-follow timer, which exists only while the follower is dead. One tmux exec and one helper exec per notice; the helper exits after every verb, so no helper process exists while idle.

Measured on an Apple M4 Pro with macOS 26.7.1, the service running with the stream on. Idle is a quiet 10.8-minute window of ordinary use, in which the hook still wrote 18 events (13 of them SubagentStop), so it is the cost of a quiet stretch rather than of a stream that never moves.

| | |
| --- | --- |
| resident memory, idle | 22.5 MiB (physical footprint 26.6 MiB); about 60 MiB right after start, before the heap settles |
| CPU, idle | 0.03 s over 10.8 minutes, 0.005 % |
| one notice, event written to helper exited | 67 ms, the median of three (67 to 76 ms) |
| wake-ups per minute, idle | 2.4, none of them from package idle |

## Adding a backend

Create `src/platform/<os>/` with a `Notifier` and, if the OS has a service manager, a `ServiceManager`, then add one line to `pickPlatform` in `src/platform/index.ts`. The engine and `src/notifier.ts` stay untouched. `test/fakes.ts` has fakes to test against, and `test/launchd.test.ts` and `test/helper.test.ts` show the pattern for a fake `Exec`.

## Development

```sh
pnpm --filter @tagents/notify test
pnpm --filter @tagents/notify typecheck
TA_NOTIFY_E2E=1 node --test test/e2e-macos.test.ts   # posts a real banner on a Mac with the app installed
```
