# status-bar-tally Specification

## Purpose
`tagents --counts` prints a compact summary of the agents for the tmux status line, and its cache and the files behind it keep the many status redraws cheap. This capability covers the text, how agents are counted, the cache and its freshness, how a running refresher keeps that cache, and the tmux option `@tagents_counts` through which the status line prints the text without running anything.

## Requirements

### Requirement: The bar's text
`tagents --counts` SHALL print one piece of tmux-styled text, with no newline added, assembled from, in this order: the config-problem marker, the tally of agents, the five-hour burn when usage is enabled, and the month-against-limit line when a usage account is watched. The first part is the `configuration` capability's and the last two are the `usage-accounting` capability's. A tmux status format prints `@tagents_counts` and runs this command only when that option is not set.

#### Scenario: A healthy config without usage
- **WHEN** `tagents --counts` runs with a config that has no problem and usage is off
- **THEN** the output is exactly the tally

#### Scenario: A config with a problem
- **WHEN** the config has one problem
- **THEN** the output starts with `#[fg=magenta]cfg!1 ` followed by the tally

### Requirement: The tally format
The tally SHALL list, in this order and only for the states that occur, `#[fg=yellow]⚠N ` for blocked agents, `#[fg=cyan]✓N ` for done agents and `#[fg=green]●N ` for working agents, and SHALL end with `#[default]`. With no agent in any of those states it is the bare `#[default]`.

#### Scenario: Three states
- **WHEN** one agent is blocked, two are working and none is done
- **THEN** the tally is `#[fg=yellow]⚠1 #[fg=green]●2 #[default]`

#### Scenario: Nothing to count
- **WHEN** there are no agents
- **THEN** the tally is `#[default]`

### Requirement: What is counted
The tally SHALL count every row the list draws by its state, except a group header: a header carries the state of its most urgent member and counting it would show one blocked agent twice. The count SHALL be the same whether the list is grouped or flat. Only blocked, done and working are shown, and the new and closed states are not.

#### Scenario: Grouped and flat give the same tally
- **WHEN** there are blocked, done and working agents spread over several projects
- **THEN** the tally of the grouped list and of the flat list is identical
- **AND** it equals the count of the non-header rows by state

### Requirement: The tally on its own
`TA_TALLY=1` with `TA_MARKS=0` in the environment of `tagents --list` SHALL make it print only the tally, with no rows and no newline, and write nothing to the state directory. `TA_MARKS=0` alone SHALL draw rows without the seat marks and write no tally file.

#### Scenario: The tally-only list
- **WHEN** `TA_MARKS=0 TA_TALLY=1 tagents --list` runs
- **THEN** its output is the tally and nothing else

### Requirement: The list leaves its tally for the refresher
A list drawn with its marks on, which is the picker's own list, SHALL write its tally to `.counts.tally` in the state directory by writing a temporary file and renaming it into place, so a reader never sees half of one. It SHALL leave no temporary file behind, and the bar's own list and a tally-only list SHALL NOT write it. A state directory that is missing or read-only simply gets no file.

#### Scenario: A marks-on list
- **WHEN** `tagents --list` runs with marks on
- **THEN** `.counts.tally` holds exactly the tally that the tally-only list prints
- **AND** no `.counts.tally.<pid>` file is left

#### Scenario: The status bar's list
- **WHEN** `TA_MARKS=0 tagents --list` runs
- **THEN** no `.counts.tally` is written

### Requirement: The bar serves a cache
`tagents --counts` SHALL print the contents of `.counts.out` in the state directory byte for byte, trailing newlines included, unless the stamp `.counts.ts` is older than `TA_COUNTS_EVERY` seconds, in which case it SHALL compute the text, write it to `.counts.out`, and print it. The default is 5 seconds. A value of `0` means every call computes, and a value that is not a number means the default.

#### Scenario: Two runs inside the interval
- **WHEN** `tagents --counts` runs twice within the interval
- **THEN** both print the same bytes
- **AND** the second run did not recompute

#### Scenario: The stamp is gone
- **WHEN** `.counts.ts` is removed
- **THEN** the next run recomputes

#### Scenario: A bad interval
- **WHEN** `TA_COUNTS_EVERY=abc`
- **THEN** the counts are still printed, as with the default interval

### Requirement: The cache is replaced atomically and stamped first
The computed text SHALL be written to a temporary file of the writer's own and renamed over `.counts.out`, so a redraw never reads half a line, and the stamp SHALL be taken before the work, so several clients redrawing at the same instant mostly read the first one's result. The stamp is the time in seconds since the epoch.

#### Scenario: A stamp that is not a number
- **WHEN** the stamp file holds junk, or does not exist
- **THEN** the cache is treated as due, without anything on stderr

### Requirement: A cached run is nearly free
A run served from the cache SHALL NOT parse the config and SHALL start no program but the one that reads the clock.

#### Scenario: A cached run
- **WHEN** the cache is fresh and `tagents --counts` runs
- **THEN** it prints the cache and starts only `date`, and no `hostname`

### Requirement: While a refresher lives, its cache is trusted
When a refresher is alive, which `tagents --counts` SHALL tell by the start marker `.refresher.<pid>.start` of a process that exists, and `.counts.out` exists, it SHALL print the cache byte for byte whatever the age of the stamp, start no program at all, and leave the stamp as it is, because a refresher that waits for events leaves a quiet dashboard's stamp old. `TA_COUNTS_EVERY=0` makes every call compute.

#### Scenario: A quiet dashboard
- **WHEN** a refresher is alive, the stamp is from 1970 and `tagents --counts` runs
- **THEN** the output is the cache, no program is started and the stamp is unchanged

#### Scenario: A dead marker
- **WHEN** the only `.refresher.<pid>.start` names a process that has exited
- **THEN** the age test applies and the bar computes the text itself

### Requirement: Computing the bar does side jobs in the background
A run that computes the text SHALL also start, in the background, the window-name sweep, throttled as the `window-names` capability describes, and the resurrect snapshot when it is due (the `resurrect` capability), so these keep up for a user who never opens the dashboard. It SHALL NOT wait for them.

#### Scenario: No dashboard
- **WHEN** only the bar runs
- **THEN** window names and the resurrect snapshot are still maintained

### Requirement: A refresher keeps the cache while its list answers
While a refresher's list answers its posts, the refresher SHALL turn the latest `.counts.tally` into `.counts.out` on every pass whose post was not refused and renew `.counts.ts`. It SHALL ignore a tally older than the refresher itself. The tally of a reload is read by the pass after it, which the second look a second later provides, so the cache is current within seconds of the last change with no further ring.

#### Scenario: First answered pass
- **WHEN** the list has written a tally, the config has one problem, and the refresher's first post is answered
- **THEN** `.counts.out` holds `#[fg=magenta]cfg!1 ` followed by the tally
- **AND** `.counts.ts` holds an epoch from after the refresher's first pass

#### Scenario: A tally from an older picker
- **WHEN** `.counts.tally` is older than the refresher's start
- **THEN** no `.counts.out` is written from it and no stamp is renewed

### Requirement: The cache is rewritten only when its text changes
The refresher SHALL replace `.counts.out` only when the text to write differs from what it wrote last, leaving no temporary file, and SHALL renew the stamp on every pass whose post was not refused either way.

#### Scenario: A repeated tally
- **WHEN** the tally is the same on the next passes
- **THEN** `.counts.out` is the same file as before while `.counts.ts` moves forward

#### Scenario: A changed tally
- **WHEN** the list writes a different tally
- **THEN** `.counts.out` holds the new text in a new file

### Requirement: The bar takes over when the list stops answering
When a post is refused, the refresher SHALL stop renewing `.counts.ts` immediately, so the bar's own computation becomes due within `TA_COUNTS_EVERY` seconds. On the slow pass, the stamp SHALL be renewed before the slow work starts, so that a long `tusage --update` cannot age it into computing in the middle of a live loop.

#### Scenario: The list goes deaf
- **WHEN** every post from the third pass on is refused
- **THEN** the stamp stays at its value from before and ages

#### Scenario: A slow update
- **WHEN** a slow pass runs `tusage --update`
- **THEN** the stamp seen by the update is newer than the one the pass began with

### Requirement: The slow parts follow the slow pass
The refresher SHALL read the burn, the month line and the config-problem marker again on every slow pass and not between them, and SHALL then rewrite the cache. A config fixed or broken under a running refresher SHALL change the marker by the next slow pass, and a fresh verdict of the same problem SHALL count once and not twice. The slow pass is described in the `refresher` capability.

#### Scenario: A burn that moves
- **WHEN** the burn changes between slow passes
- **THEN** the cache holds the old burn until the slow pass and the new one after it

#### Scenario: A config fixed under the refresher
- **WHEN** the config problem is fixed while the refresher runs
- **THEN** the marker is gone from the cache by the next slow pass

#### Scenario: A config broken under the refresher
- **WHEN** a good config gets a problem
- **THEN** the marker appears by the next slow pass

### Requirement: The refresher composes what the bar would print
The text the refresher builds from the parts and a tally SHALL equal, byte for byte, what a full computation of the bar prints for the same state, with or without a config problem.

#### Scenario: Equal bytes
- **WHEN** both are produced for the same agents and the same config
- **THEN** the outputs are identical and contain the tally

### Requirement: The bar's text is also a tmux option
While a refresher keeps the cache, it SHALL set the global tmux option `@tagents_counts` to the same text as `.counts.out`, byte for byte, and only when that text changes. It SHALL unset the option when it ends and no other refresher is alive, and a sidebar list that closes SHALL unset it when no refresher with a live process remains while a popup list SHALL NOT, so that a refresher killed with -9 does not leave the last text on the bar for good.

#### Scenario: The option follows the cache
- **WHEN** the tally changes while a refresher runs
- **THEN** `@tagents_counts` holds the new text, and the old text is not set again while the tally stays the same

#### Scenario: Taken down
- **WHEN** the last refresher ends
- **THEN** `@tagents_counts` is unset

### Requirement: The status line prints the option and falls back to the command
The status-line fragment `#{?@tagents_counts,#{@tagents_counts},#(~/.local/bin/tagents --counts)}` SHALL print the option when it is set, without running any program, and run `tagents --counts` only when it is not. With no refresher the option is not set and the bar computes the text itself, throttled by `TA_COUNTS_EVERY`.

#### Scenario: A dashboard is open
- **WHEN** a refresher is keeping the option and the status line redraws
- **THEN** the bar prints the option and `tagents --counts` is not started

#### Scenario: No dashboard
- **WHEN** no refresher is alive
- **THEN** the option is unset and the redraw runs `tagents --counts`
