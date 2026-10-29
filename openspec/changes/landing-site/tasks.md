## 1. The project

- [x] 1.1 `site/` is its own pnpm project with its own lockfile and the root files are untouched (`git diff --stat origin/main -- contract.json .claude-plugin skills pnpm-lock.yaml pnpm-workspace.yaml` prints nothing; `pnpm install --frozen-lockfile` in `site/`)
- [x] 1.2 The build writes `index.html`, `404.html`, `robots.txt` and `.nojekyll`, and `CNAME` and `sitemap.xml` only with `SITE_DOMAIN` (`pnpm build` in `site/`; `build/outputs.test.ts`, `build/site-config.test.ts`)
- [x] 1.3 Every internal link and fragment of the build resolves and nothing a page or stylesheet loads comes from another site (`pnpm check:links` in `site/`; `build/links.test.ts`)

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
- [x] 3.5 The words give no claim about speed, memory or a comparison, and the commands are the README's (`src/content.test.ts`)
- [x] 3.6 The head names no address without `SITE_DOMAIN` and names it with one (`src/lib/head.test.ts`; `pnpm build` with and without `SITE_DOMAIN=tagents.example.org`)

## 4. The mascot

- [x] 4.1 The sprite is a valid rectangle of known colours, the credit says what it must, and no source file outside `src/mascot/` names the mascot (`src/mascot/mascot.test.ts`)

## 5. Publishing

- [x] 5.1 One workflow builds and checks the site and the documentation and deploys only on `main` (`grep -n "refs/heads/main\|deploy-pages\|upload-pages\|pages: write" .github/workflows/site.yml` finds the conditions on the upload and on the deploy job; the checks of a pull request show the deploy job skipped)
- [x] 5.2 The documentation workflow is gone and the documentation is built with the base `/docs/` (`git ls-files .github/workflows`; `pnpm docs:build` writes assets under `/docs/assets/`)
- [x] 5.3 The README links to the documentation at `tagents.arstoien.com/docs/`, and `docs/development.md` to the site at `tagents.arstoien.com` (`git grep -n "https://skuratovicha.github.io" -- . ':!openspec/changes'` finds nothing)
- [x] 5.4 The link check requires `docs/index.html`, resolves the links into it and reads none of its pages, and the prerender writes nothing under `docs/` (`build/links.test.ts`, `build/prerender.test.ts`, `src/lib/site.test.ts`, and the step of `site.yml` that copies the documentation and fails when the site build already wrote `dist/client/docs`; with `SITE_DOMAIN=tagents.arstoien.com`, `pnpm check:links` fails on a build without the copy of the documentation and passes with it)

## 6. The spec

- [x] 6.1 The change is valid OpenSpec (`pnpm spec:check` at the repository root)
- [ ] 6.2 Archiving the change replaces the placeholder Purpose that `openspec archive` writes for the new capability `site` in `openspec/specs/site/spec.md` with its own sentence, by hand, before `pnpm spec:check` is run on the archived specs
