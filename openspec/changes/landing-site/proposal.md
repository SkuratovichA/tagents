## Why

tagents has a README, a documentation site and four screenshots, but nothing that shows a visitor in a few seconds what it is for: a dashboard that tells you which of your Claude Code chats is waiting on you. The documentation site is reference material, and a README cannot play a recording of the real dashboard. A one-page site can, in the style of its sibling gsttt-site and with Pikachu as its mascot.

## What Changes

- A one-page site in `site/`: a title and pitch, the real dashboard playing in a terminal, what it does, three closer looks, how a restart is survived, how to install it, and the notifications, status bar and plugin.
- The page is complete HTML without scripts, loads nothing from another site, follows the system's light or dark preference, respects a request for less motion and fits a 360 pixel screen.
- The four recordings are made from the real dashboard by `pnpm capture`, on a scratch tmux server with the made-up chats of `docs/demo`, and stored as data of about 100 KB.
- The mascot is pixel art drawn from a supplied picture. Every file that names it is in `site/src/mascot/` or `site/public/mascot/`, and the footer says the site is an unaffiliated fan tribute.
- One workflow, `.github/workflows/site.yml`, lints, type-checks, tests, builds and link-checks the site and builds the documentation when `site/`, `docs/` or an input of their builds changes, and on a push to `main` deploys both as one GitHub Pages deployment: the page at `/` and the documentation under `/docs/`.
- The documentation moves to `/docs/`: its VitePress base changes, and the footer of the page and the README link to it. The documentation workflow `docs.yml` goes, because a repository has one Pages artifact and two workflows would replace each other.
- The site is served at `tagents.arstoien.com`, and every build sets `SITE_DOMAIN` to it.

## Capabilities

### New Capabilities

- `site`: the one-page site of tagents, as a visitor and as a maintainer who builds it can observe it.

### Modified Capabilities

None.

## Impact

- Affected specs: `site` (new).
- Affected code: `site/` (new, its own pnpm project with its own lockfile), `.github/workflows/site.yml` (new, replaces `docs.yml`), `docs/.vitepress/config.mjs` (base), `README.md` and `docs/development.md` (links and the publishing notes).
- Not affected: `contract.json`, `.claude-plugin/`, `skills/`, the root `pnpm-lock.yaml` and `pnpm-workspace.yaml`, and the content of the documentation pages.
