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

#### Scenario: A page or stylesheet that loads from another site
- **WHEN** a built page or stylesheet loads a font, script, style or image from another site
- **THEN** `pnpm check:links` fails and names the file and the address (`build/links.test.ts`)

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

#### Scenario: Focus on a terminal
- **WHEN** a scrollable terminal receives keyboard focus
- **THEN** a focus ring is visible around it (`src/components/chrome.test.tsx`)

#### Scenario: Buttons that say what they do
- **WHEN** the page lists its recordings and the theme button
- **THEN** each Play or Replay button has an accessible name of its own that names its recording
- **AND** the theme button's `aria-pressed` says whether the dark theme is on (`src/components/chrome.test.tsx`)

### Requirement: The page makes no claim about speed or resources and compares with nothing
The words on the page SHALL describe what tagents does as its README does. They SHALL give no figure or claim about speed, memory or processor use and no comparison with another tool. The install command SHALL be the README's, and the page SHALL say, as the README does, that the install ends by running `tagents setup`, which only appends to the `settings.json` files.

#### Scenario: A change to the copy
- **WHEN** a word about speed, memory or a comparison is added to the page
- **THEN** `pnpm test` in `site/` fails

#### Scenario: The README changes its install command
- **WHEN** the install command in `README.md` differs from the one on the page
- **THEN** `pnpm test` in `site/` fails

#### Scenario: The README or the page stops saying what the install does to the settings
- **WHEN** the README or the page no longer says that the install runs `tagents setup` and that it only appends
- **THEN** `pnpm test` in `site/` fails

### Requirement: The site builds with named commands
In `site/`, `pnpm install --frozen-lockfile`, `pnpm lint`, `pnpm typecheck`, `pnpm test` and `pnpm build` SHALL each succeed on a fresh clone. `pnpm build` SHALL write `dist/client` with `index.html`, `404.html`, `robots.txt` and `.nojekyll`. `pnpm check:links` SHALL succeed on a build to which the documentation has been copied (`dist/client/docs/`).

#### Scenario: A build without a domain
- **WHEN** `pnpm build` runs with `SITE_DOMAIN` unset
- **THEN** `dist/client` has `index.html`, `404.html`, `robots.txt` and `.nojekyll`

### Requirement: The page names its own address only when it has one
A build SHALL write `CNAME` and `sitemap.xml`, and SHALL name the page's own address in its head, only when `SITE_DOMAIN` is set.

#### Scenario: A build without a domain
- **WHEN** `pnpm build` runs with `SITE_DOMAIN` unset
- **THEN** `dist/client` has no `CNAME` and no `sitemap.xml`
- **AND** `index.html` has no canonical link, no `og:url` and no `og:image`

#### Scenario: The 404 page with a domain
- **WHEN** `SITE_DOMAIN` is set and the 404 page is built
- **THEN** it carries no canonical link and no `og:url`, because it is served at every address (`src/routes/notFoundRoute.test.ts`)

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
Every file that names the mascot SHALL be in `site/src/mascot/` or `site/public/mascot/`, so that replacing the mascot is a change to those two directories alone. The footer SHALL say that the mascot is a fan tribute, that the site is not affiliated with or endorsed by the owners of the character (Nintendo, Creatures Inc., GAME FREAK inc. and The Pokémon Company) and that Pokémon and Pokémon character names are trademarks of Nintendo.

#### Scenario: Another source file names the mascot
- **WHEN** a file of `site/src/` outside `site/src/mascot/` contains the mascot's name
- **THEN** `pnpm test` in `site/` fails

### Requirement: The footer carries the credit and the way to the repository
The footer SHALL print the credit of the mascot and link to GitHub, to the documentation under `/docs/` of the same site and to the repository's licence, the `LICENSE` file, in that order.

#### Scenario: Reading the footer
- **WHEN** the footer is rendered
- **THEN** it carries the credit of the mascot module
- **AND** it links to GitHub, to the documentation at `/docs/` of the site and to the `LICENSE` file of the repository

### Requirement: One workflow checks the site and the documentation and publishes both
The workflow SHALL lint, type-check, test, build and link-check the site and build the documentation whenever `site/`, `docs/`, the workflow itself, `.node-version`, the root `package.json` or the root `README.md` changes, with `SITE_DOMAIN` set to `tagents.arstoien.com` and Node from `.node-version`. Only on `main` SHALL it deploy, as one GitHub Pages deployment: the page at `/` and the documentation under `/docs/`.

#### Scenario: A pull request that edits the documentation
- **WHEN** a pull request changes files under `docs/`
- **THEN** the workflow builds and checks the site and the documentation
- **AND** it deploys nothing

#### Scenario: A push to the main branch
- **WHEN** a push to `main` changes files under `site/` or `docs/`
- **THEN** one deployment holds the page at `/` and the documentation at `/docs/`

#### Scenario: A manual run on another branch
- **WHEN** the workflow is started by hand on a branch other than `main`
- **THEN** it deploys nothing

#### Scenario: The build for the domain
- **WHEN** the workflow builds the site
- **THEN** `dist/client/CNAME` holds `tagents.arstoien.com`

### Requirement: The link check resolves links into the documentation and does not read its pages
The link check SHALL require `docs/index.html` in the build output, resolve the links that lead into `docs/` against its files, and read none of the pages under `docs/`. The prerender SHALL write no page under `docs/`, so that no page of the site can stand in for the documentation.

#### Scenario: The documentation is missing
- **WHEN** `pnpm check:links` runs on a build without `docs/index.html`
- **THEN** it fails and names `docs/index.html`
- **AND** it reports the links to `/docs/` as pointing at no file

#### Scenario: The documentation is present
- **WHEN** `pnpm check:links` runs on a build with the documentation copied to `dist/client/docs/`
- **THEN** it resolves the links to `/docs/` and reads none of the pages under `docs/`
- **AND** a link to a fragment in `/docs/` is resolved to the file, and the fragment is not looked for

#### Scenario: Building the site
- **WHEN** `pnpm build` runs in `site/`
- **THEN** it writes no file under `dist/client/docs/`: `build/prerender.test.ts` pins the prerender filter, and the workflow step that copies the documentation fails when that directory already exists
