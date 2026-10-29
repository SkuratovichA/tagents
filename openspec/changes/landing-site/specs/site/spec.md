## ADDED Requirements

### Requirement: The page works without scripts
The page SHALL be complete HTML before any script runs: its text, its links, the install command and every recording on its last frame. Scripts SHALL only play the recordings again and switch the theme, and the controls that need them SHALL be hidden while scripts do not run.

#### Scenario: A visitor with scripts turned off
- **WHEN** the page is opened with JavaScript disabled
- **THEN** every section, the install command and the link to the repository are there
- **AND** each recording shows the last frame it was recorded to, and no Play, Replay or theme control is shown

### Requirement: The page loads nothing from another site
Every font, script, style and image the page needs SHALL be served by the site itself, and the page SHALL contain no analytics, tracking or third-party embed.

#### Scenario: The network list of one visit
- **WHEN** the page is opened and scrolled to the end with scripts on
- **THEN** every request goes to the origin the page was served from

### Requirement: The recordings play once and respect a request for less motion
A recording SHALL play from its first frame to its last once, when at least half of it has come into view, and SHALL stay on its last frame afterwards, with a Replay button to play it again. For a visitor whose system asks for reduced motion, a recording SHALL stay on its last frame until the visitor presses Play, and the page SHALL run no CSS animation or transition.

#### Scenario: A recording scrolls into view
- **WHEN** a recording becomes half visible
- **THEN** it plays from its first frame to its last at the pace it was recorded
- **AND** it does not start again by itself

#### Scenario: Reduced motion
- **WHEN** the system asks for reduced motion
- **THEN** every recording shows its last frame and a Play button
- **AND** pressing Play plays that recording once

### Requirement: The recordings are the real dashboard
Each recording SHALL be a capture of the real `tagents` dashboard running on a scratch tmux server, with the made-up chats of `docs/demo`, and SHALL contain nothing of the machine it was captured on. `pnpm capture` SHALL redo them without touching the tmux server it is started from, the Claude accounts or the user's tagents state, and SHALL stop both scratch servers when it ends.

#### Scenario: Recording one scene again
- **WHEN** `pnpm capture keys` runs in `site/` on a machine with a tmux server of its own already running
- **THEN** `site/src/demos/data/keys.ts` is rewritten
- **AND** the running tmux server still has its sessions and no scratch server is left

### Requirement: The page uses light and dark themes
The page SHALL follow the system's light or dark preference. A visitor with scripts SHALL be able to choose a theme, and the choice SHALL be remembered in the browser and applied before the first paint. The terminals SHALL be dark in both themes.

#### Scenario: A stored choice
- **WHEN** a visitor whose system prefers light has chosen dark and opens the page again
- **THEN** the page is dark from its first paint

### Requirement: The page fits a small screen and the keyboard
The page SHALL cause no horizontal scrolling of the document at a width of 360 pixels. A recording that is wider than its box and a code block that is wider than its box SHALL scroll inside their own box, which SHALL be reachable and scrollable with the keyboard.

#### Scenario: A phone
- **WHEN** the page is opened at a width of 360 pixels
- **THEN** the document is not wider than the screen
- **AND** each recording can be scrolled sideways inside its terminal

### Requirement: The page makes no claim about speed or resources and compares with nothing
The words on the page SHALL describe what tagents does as its README does. They SHALL give no figure or claim about speed, memory or processor use, no comparison with another tool and no licence. The install command and the `settings.json` SHALL be those of the README.

#### Scenario: A change to the copy
- **WHEN** a word about speed, memory or a comparison is added to the page
- **THEN** `pnpm test` in `site/` fails

#### Scenario: The README changes its install command
- **WHEN** the install command in `README.md` differs from the one on the page
- **THEN** `pnpm test` in `site/` fails

### Requirement: The site builds with named commands
In `site/`, `pnpm install --frozen-lockfile`, `pnpm lint`, `pnpm typecheck`, `pnpm test`, `pnpm build` and `pnpm check:links` SHALL each succeed on a fresh clone. `pnpm build` SHALL write `dist/client` with `index.html`, `404.html`, `robots.txt` and `.nojekyll`.

#### Scenario: A build without a domain
- **WHEN** `pnpm build` runs with `SITE_DOMAIN` unset
- **THEN** `dist/client` has `index.html`, `404.html`, `robots.txt` and `.nojekyll`
- **AND** `pnpm check:links` finds every internal link and fragment

### Requirement: The page names its own address only when it has one
A build SHALL write `CNAME` and `sitemap.xml`, and SHALL name the page's own address in its head, only when `SITE_DOMAIN` is set.

#### Scenario: A build without a domain
- **WHEN** `pnpm build` runs with `SITE_DOMAIN` unset
- **THEN** `dist/client` has no `CNAME` and no `sitemap.xml`
- **AND** `index.html` has no canonical link, no `og:url` and no `og:image`

#### Scenario: A build with a domain
- **WHEN** `pnpm build` runs with `SITE_DOMAIN=tagents.example.org`
- **THEN** `dist/client/CNAME` holds `tagents.example.org`
- **AND** `index.html` has a canonical link to `https://tagents.example.org/`

### Requirement: The site is its own pnpm project
The site SHALL have its own `package.json` and lockfile, and installing or building it SHALL NOT change the root `pnpm-lock.yaml`, `pnpm-workspace.yaml`, `contract.json` or the plugin.

#### Scenario: Installing the site
- **WHEN** `pnpm install` runs in `site/`
- **THEN** `git status` of the repository lists no file outside `site/`

### Requirement: The mascot lives in one place and is credited
Every file that names the mascot SHALL be in `site/src/mascot/` or `site/public/mascot/`, so that replacing the mascot is a change to those two directories alone. The footer SHALL say that the mascot is a fan tribute, that the site is not affiliated with the owners of the character and whose trademark it is.

#### Scenario: Another source file names the mascot
- **WHEN** a file of `site/src/` outside `site/src/mascot/` contains the mascot's name
- **THEN** `pnpm test` in `site/` fails

### Requirement: Nothing in this repository publishes the site
This repository SHALL hold no workflow, setting, domain file or link that deploys the site or names its address. Its workflow SHALL only lint, type-check, test, build and link-check, with read access to the repository, and SHALL run only when `site/` or the workflow itself changes.

#### Scenario: A pull request that only edits the documentation
- **WHEN** a pull request changes files under `docs/` only
- **THEN** the site workflow does not run
