## Decisions to review

Each decision is one line, the reason in a clause, what was rejected, and the code that carries it.

1. **The site is its own pnpm project in `site/`**, because the root lockfile, the root workspace and the plugin contract must not move for a web page. Rejected: a workspace package, which would change the root `pnpm-lock.yaml` and make every plugin change install a web stack.

   ```yaml
   # site/pnpm-workspace.yaml: stops pnpm from finding the root workspace one directory up
   packages:
     - '.'
   ```

2. **The stack is gsttt-site's (read at commit a0583d7)**: TanStack Start prerendering one route, Vite, Tailwind 4, Vitest, strict ESLint, Prettier, self-hosted Fontsource fonts, and its design language of 2px borders, hard offset shadows and a dot lattice, with the same token and dark-theme structure. The reason is that the build already solves trailing slashes, `404.html`, a base path and a domain-less build, and the two sites should look like siblings. Rejected: a hand-written HTML page, which has no tests for the page's promises, and Astro, which is a second stack to keep up. Left out of the copy: the documentation pages, i18next, the benchmark data and Effect, which this repository does not use and which a page with no failure to model does not need (the types already carry the shape and the tests check ranges plainly).

   ```ts
   // site/vite.config.ts
   tanstackStart({
     prerender: prerenderOptions(site.base), // crawls links, and its filter skips the paths under a mount
     pages: [{ path: '/404', prerender: { outputPath: '/404.html' } }],
   })
   ```

3. **The HTML is complete without scripts and holds each recording's last frame**, because a visitor with scripts off, a crawler and a link preview should see the dashboard doing something, not an empty box. Scripts rewind to the first frame after hydration and play. Rejected: drawing the terminal only on the client.

   ```ts
   // site/src/lib/useDemo.ts: the server and the first client render both show the last frame
   const [frame, setFrame] = useState(scene.frames.length - 1)
   ```

4. **The recordings are captured from the real dashboard**, not drawn: `pnpm capture` runs `docs/demo/world.sh` (fake agents, a fake `claude`, a throwaway home) on a scratch tmux server, attaches a second scratch tmux server to it, types the steps of a scene and samples `tmux capture-pane -e -p` every 100 milliseconds. Rejected: the VHS tapes of `docs/demo`, which make GIFs (heavy, not text, not zoomable), and an asciinema player (a third-party script and format). The nesting is needed because the dashboard is a client of its own tmux server, so a capture has to be taken from outside it.

   ```ts
   // site/capture/scenes.ts
   { id: 'hero', until: 11_000, steps: [
     { at: 1_500, ctl: ['api', "permit 'pnpm test --filter api'"] },
     ...down(3_500, 8),
     { at: 7_000, keys: ['Enter'] },
   ] }
   ```

5. **A recording is stored as data of styled runs, with each frame holding only the rows that changed**: about 100 KB before compression and about 10 KB gzipped for all four. The data is typed TypeScript modules, so the compiler checks their shape and `pnpm test` checks the ranges the type cannot (row and style indexes, time order, glyph coverage). Rejected: JSON read at run time, which needs a cast; a schema library such as the Effect `Schema` gsttt-site uses for its benchmark file, because this repository uses none and the types already carry the shape.

   ```ts
   // site/src/lib/screen.ts
   export type Run = readonly [text: string, style: number]
   export interface Frame { readonly t: number; readonly rows: readonly (readonly [row: number, content: Row])[] }
   ```

6. **A recording plays once and stops on its last frame, with a Replay button**, because a looping terminal is a distraction beside the text and the last frame is the one the page holds without scripts. With reduced motion it waits for Play. Rejected: a loop, and playing at page load, which would finish before the visitor scrolls to it.

   ```ts
   // site/src/lib/useDemo.ts
   new IntersectionObserver(([entry]) => { if (entry?.isIntersecting) { observer.disconnect(); play() } }, { threshold: 0.5 })
   ```

7. **The terminal is one font for every cell, DejaVu Sans Mono cut to the 124 characters the recordings use** (7 KB per weight, its licence beside it), because box drawing, block bars and state marks must each be exactly one cell wide, and a fallback font would shift every column. `⎿`, which that font lacks, is drawn as `└`. `pnpm font` refuses to write a font that lacks a character a recording uses, and a test pins the recordings to `public/fonts/glyphs.txt`. Rejected: the page's code font Martian Mono for terminals, whose cell width and glyph set are not the terminal's.

   ```css
   .screen { font-size: max(8px, calc(100cqw / (var(--cols) * 0.602))); line-height: 1.164; }
   ```

8. **A terminal shrinks to fit its box and scrolls sideways below 8px**, so a desktop sees the whole 160-column screen and a phone sees a readable part of it. Rejected: scaling down without a limit, which makes the text unreadable on a phone, and a fixed font size, which scrolls on every screen.

9. **The mascot is pixel art generated once from the supplied picture and drawn as SVG rectangles**: 48 columns, eight colours, 2.6 KB, crisp at any size, with the icons and the social card made by the same generator. Every file that names it is in `site/src/mascot/` or `site/public/mascot/`, and the footer prints the credit the mascot module exports, so replacing the mascot is a change to those two directories. Rejected: serving the picture itself, which is a raster with a sticker border and no theme.

   ```ts
   // site/src/mascot/index.ts: the only door the rest of the site uses
   export { MASCOT, Mascot } from './Mascot'
   ```

10. **Colours are gsttt-site's blues and navy with the mascot's yellow `#f6b828` for the main buttons and step numbers**, and the terminals are dark in both themes (the colours of Catppuccin Mocha, the theme of the screenshots in `docs/images`). The dark tokens are written twice, for the system preference and for an explicit choice, and a test keeps the two blocks identical.

11. **Until `SITE_DOMAIN` is set at build time the page names no address of its own**: no canonical link, `og:url`, `og:image`, sitemap or `CNAME`, because a relative one would point nowhere and the address is not decided. `robots.txt` and `.nojekyll` are always written.

    ```ts
    // site/src/lib/head.ts
    if (origin === null) return { meta, links: [] }
    ```

12. **The words are the README's**, one paragraph per feature, with no claim about speed, memory or resources and no comparison. A test pins the install command, the `settings.json` and the other commands to `README.md` (skipped when the README is not beside the site), and a test fails on words of speed, memory or comparison.

13. **One workflow, `site.yml`, checks and publishes the site and the documentation**, filtered to `site/**`, `docs/**`, itself, `.node-version` and the root `package.json` and `README.md` (the first pins the VitePress version, the second holds the install command the page repeats), whose Node version it uses, with the SHA-pinned actions of gsttt-site. Its checks hold `contents: read`; a deploy job that runs on `main` only holds `pages: write` and `id-token: write`. A repository has one Pages artifact, so a second workflow that deploys would replace the first, and the documentation workflow it supersedes is deleted. `SITE_DOMAIN=tagents.arstoien.com` is set for every build, so the build that is checked is the build that is published. Rejected: a job in `ci.yml`, which would install the site's stack for every plugin change, and a repository of its own for the site, which splits the project in two for the sake of a second Pages site.

    ```yaml
    # .github/workflows/site.yml
    deploy:
      needs: verify
      if: github.ref == 'refs/heads/main'
      permissions: { contents: read, pages: write, id-token: write }
    ```

14. **English only, one route, and the documentation under `/docs/`.** No language switcher; the documentation is the VitePress site of `docs/`, built with its base set to `/docs/` and served beside the page, and the footer of the page links to it.

15. **The documentation directory is a mount that the build and the link check of the site know by name**: `MOUNTS` in `site/build/links.ts` lists `docs/`. The prerender skips every path under a mount, because the router has no routes there and a crawled link to `/docs/` would write the router's not-found page to `docs/index.html`, which the link check would then accept as the documentation. The link check requires `docs/index.html`, resolves links into the mount and reads none of its pages, because VitePress checks its own. Rejected: a check that does not know the documentation, which turns the footer link into a broken link, and scanning the documentation's pages with the site's checker, which would report output that is not the site's to fix.

    ```ts
    // site/build/links.ts
    export type Mount = `${string}/`
    export const MOUNTS: readonly Mount[] = ['docs/']
    ```

    VitePress is fixed at `/docs/` and the footer link follows the base of the site, so a base other than `/` cannot be served together with a mount: `pnpm check:links` fails on it (`mountsNeedRootBase`).

## Publishing

The workflow publishes on every push to `main` that touches `site/`, `docs/`, the workflow, `.node-version`, the root `package.json` or the root `README.md`, as one deployment: the page at `/` and the documentation at `/docs/`. The first publication has an order, because once the custom domain is set GitHub Pages redirects the project address `skuratovicha.github.io/tagents/` to it, and a page built for another base would load no assets there. First a deployment built with `SITE_BASE=/` and `SITE_DOMAIN=tagents.arstoien.com` succeeds; then a CNAME record `tagents` for `arstoien.com` pointing at `skuratovicha.github.io` is created at whoever hosts the DNS of `arstoien.com`; then `tagents.arstoien.com` is set as the custom domain in the Pages settings of the repository; and HTTPS is enforced after GitHub has issued the certificate. The documentation pages that were served at `skuratovicha.github.io/tagents/<page>` stop resolving when the domain is set: they are at `tagents.arstoien.com/docs/<page>`.

## Open questions for Sasha

1. Keep the Pikachu artwork or replace it? The picture comes from https://mystickermania.com/sticker-packs/memes/surprised-pikachu and the character belongs to Nintendo, Creatures Inc., GAME FREAK inc. and The Pokémon Company; the footer says the mascot is a fan tribute, that the site is not affiliated with or endorsed by those four companies and that Pokémon and Pokémon character names are trademarks of Nintendo. That last sentence is the usual notice and is unverified against the official one, whose page could not be read while writing it. Replacing the artwork is a change to `site/src/mascot/` and `site/public/mascot/` only.
2. The repository is MIT-licensed (`LICENSE` at its root), and the footer links to that file next to GitHub and Docs, the link built from the repository address in `site/src/lib/site.ts`. The words of the page still say nothing about a licence.
