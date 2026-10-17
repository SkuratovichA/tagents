# @tagents/notify

Desktop notifications for tagents: a banner when an agent needs you, and a click that docks that chat.

It watches the agents' event stream and posts one notice when something wants your attention. The kinds are `question` (AskUserQuestion, plan approval, MCP elicitation), `permission` (a permission prompt), `turn_done` (the answer is ready, your move), `cache_expiring` (the prompt cache is about to run out), `subagent_done` and `session_end`. The first four are on by default; the last two are off. Each session has one notice at a time: a later notice replaces the earlier one instead of stacking, and a notice that is no longer true is withdrawn.

The engine only knows a `Notifier`. What posts the banner is the platform layer under `src/platform/`, and macOS is the one backend today.

## Install

```sh
tagents notify install
```

On macOS this builds the helper app if it is stale, asks for permission, then writes and starts a LaunchAgent that runs the engine in the background. Allowing notifications:

1. `tagents notify install` makes macOS ask whether "tagents" may send notifications: Allow.
2. If the prompt was missed: System Settings → Notifications → tagents → Allow notifications. "Banners" is the default style; "Alerts" keeps a notice until it is dismissed.
3. Focus and Do Not Disturb hide banners; the notices still land in Notification Center.
4. `tagents notify status` must say `permission: authorized`.

macOS may announce a new background item in System Settings → General → Login Items & Extensions; it must stay allowed or launchd will not start the service.

Elsewhere `install` refuses with "no notification backend for <os> yet" and exits 2.

## Configuration

`<configDir>/plugins/notify.yaml`. Every key is optional; these are the defaults:

```yaml
backend: auto      # auto | macos | log | none — auto: macos on darwin, none elsewhere
click: dock        # dock: like Enter in the list · goto: the agent's own window · focus: terminal only
sessions:
  headless: false  # sessions with no tmux pane: claude -p from a daemon, IDE sessions
events:
  question:       { enabled: true,  skip_visible: true }   # AskUserQuestion, plan approval, MCP elicitation
  permission:     { enabled: true,  skip_visible: true }   # a permission prompt
  turn_done:      { enabled: true,  skip_visible: true }   # the answer is ready, your move
  cache_expiring: { enabled: true,  skip_visible: false, after: 50m, ttl: 60m }
  subagent_done:  { enabled: false, skip_visible: true }
  session_end:    { enabled: false, skip_visible: true }
```

Durations are `<n>s|m|h`, combined like `1h30m`, or a bare number of seconds, and `after` must be below `ttl`.

`skip_visible`: when the agent's tmux pane is in some client's current window and that terminal is the frontmost app, the notice is dropped.

An invalid file is logged once per problem and the engine runs on the defaults; `tagents notify status` prints the problems. The file is reloaded when it changes, so there is nothing to restart.

## Clicking a notice

`click: dock` runs `tagents --act open <pane> live <sid> <cwd>`, the same as Enter in the dashboard list. `click: goto` runs `tagents --goto <pane>`. `click: focus`, or a session with no pane, only raises the terminal.

## Commands

| | |
| --- | --- |
| `tagents notify run` | the engine in the foreground until SIGTERM or SIGINT; this is what the LaunchAgent runs |
| `tagents notify install` | on macOS: build the app if stale, ask for permission, write and bootstrap the LaunchAgent, print the status and the steps |
| `tagents notify uninstall [--purge]` | boot the service out, delete the plist, switch the event stream off; `--purge` deletes the app too |
| `tagents notify status` | platform, backend, app (built or stale), permission, LaunchAgent (installed, running, pid), stream on or off, the options file and its problems, the service's memory |
| `tagents notify test [--kind <kind>]` | post one sample notice now through the platform notifier; a click docks `$TMUX_PANE` when it is set |

## Resources

No polling. One `fs.watch` on the state directory, one on the options directory, and at most one timer, which exists only while a cache deadline is armed and sleeps 5 minutes at most. One tmux exec and one helper exec per notice; the helper exits after every verb, so no helper process exists while idle.

## Adding a backend

Create `src/platform/<os>/` with a `Notifier` and, if the OS has a service manager, a `ServiceManager`, then add one line to `pickPlatform` in `src/platform/index.ts`. The engine and `src/notifier.ts` stay untouched. `test/fakes.ts` has fakes to test against, and `test/launchd.test.ts` and `test/helper.test.ts` show the pattern for a fake `Exec`.

## Development

```sh
pnpm --filter @tagents/notify test
pnpm --filter @tagents/notify typecheck
TA_NOTIFY_E2E=1 node --test test/e2e-macos.test.ts   # posts a real banner on a Mac with the app installed
```
