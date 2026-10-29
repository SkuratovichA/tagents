## 1. The project

- [x] 1.1 `site/` is its own pnpm project with its own lockfile and the root files are untouched (`git diff --stat origin/main -- contract.json .claude-plugin skills pnpm-lock.yaml pnpm-workspace.yaml` prints nothing; `pnpm install --frozen-lockfile` in `site/`)
- [x] 1.2 The build writes `index.html`, `404.html`, `robots.txt` and `.nojekyll`, and `CNAME` and `sitemap.xml` only with `SITE_DOMAIN` (`pnpm build` in `site/`; `build/outputs.test.ts`, `build/site-config.test.ts`)
- [x] 1.3 Every internal link and fragment of the build resolves (`pnpm check:links` in `site/`; `build/links.test.ts`)

## 2. The recordings

- [x] 2.1 `pnpm capture` records a scene from the real dashboard on scratch tmux servers and tears them down (`pnpm capture keys` in `site/`, then `tmux -S /tmp/tagents-site-cap/outer.sock ls` reports no server)
- [x] 2.2 The escape sequences of a capture become styled runs, and an unknown one stops the capture (`capture/ansi.test.ts`)
- [x] 2.3 A recording is stored as the rows that changed and replays to the screens it was made from (`capture/frames.test.ts`, `src/lib/screen.test.ts`)
- [x] 2.4 Every recording has valid indexes, rising times, rows within the screen, only characters of the terminal font and nothing of the machine it was captured on (`src/demos/demos.test.ts`)

## 3. The page

- [x] 3.1 The page rendered as the server sends it holds every recording on its last frame, the install command and no request to another site (`src/components/Home.test.tsx`; the network list of a visit in a headless browser, in the pull request)
- [x] 3.2 A recording plays once, can be replayed, and waits for Play under reduced motion (`src/components/Home.test.tsx`)
- [x] 3.3 The themes follow the system, a stored choice is applied before the first paint, the dark tokens are the same twice and the terminal colours are the recorded ones (`src/lib/theme.test.ts`, `src/styles.test.ts`)
- [x] 3.4 No horizontal scrolling of the document at 360 and 390 pixels and none at 1440, and no console message (a headless browser run of `pnpm preview` at 1440, 390 and 360 pixels, light and dark, in the pull request)
- [x] 3.5 The words give no claim about speed, memory or a comparison and no licence, and the commands are the README's (`src/content.test.ts`)
- [x] 3.6 The head names no address without `SITE_DOMAIN` and names it with one (`src/lib/head.test.ts`; `pnpm build` with and without `SITE_DOMAIN=tagents.example.org`)

## 4. The mascot

- [x] 4.1 The sprite is a valid rectangle of known colours, the credit says what it must, and no source file outside `src/mascot/` names the mascot (`src/mascot/mascot.test.ts`)

## 5. Publishing

- [x] 5.1 The workflow only reads the repository, runs only for `site/` and itself, and has no deploy step (`actionlint .github/workflows/site.yml`; `grep -n "SITE_DOMAIN\|CNAME\|deploy-pages\|upload-pages" .github/workflows/site.yml` finds nothing)
- [x] 5.2 No file outside `site/`, `openspec/changes/landing-site/` and the workflow names the site (`git diff --stat origin/main` lists nothing else)

## 6. The spec

- [x] 6.1 The change is valid OpenSpec (`pnpm spec:check` at the repository root)
