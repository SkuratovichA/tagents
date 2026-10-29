## Decisions to review

Each decision is one line, the reason in a clause, what was rejected, and the code that carries it.

1. **The site is its own pnpm project in `site/`**, because the root lockfile, the root workspace and the plugin contract must not move for a web page. Rejected: a workspace package, which would change the root `pnpm-lock.yaml` and make every plugin change install a web stack.

   ```yaml
   # site/pnpm-workspace.yaml: stops pnpm from finding the root workspace one directory up
   packages:
     - '.'
   ```

2. **The stack is gsttt-site's (read at commit a0583d7)**: TanStack Start prerendering one route, Vite, Tailwind 4, Vitest, strict ESLint, Prettier, self-hosted Fontsource fonts, and its design language of 2px borders, hard offset shadows and a dot lattice, with the same token and dark-theme structure. The reason is that the build already solves trailing slashes, `404.html`, a base path and a domain-less build, and the two sites should look like siblings. Rejected: a hand-written HTML page, which has no tests for the page's promises, and Astro, which is a second stack to keep up. Left out of the copy: the documentation pages, i18next and the benchmark data.

   ```ts
   // site/vite.config.ts
   tanstackStart({
     prerender: { enabled: true, crawlLinks: true, failOnError: true },
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

12. **The words are the README's**, one paragraph per feature, with no claim about speed, memory or resources, no comparison and no licence (the repository has none). A test pins the install command, the `settings.json` and the other commands to `README.md` (skipped when the README is not beside the site), and a test fails on words of speed, memory or comparison.

13. **A workflow of its own, `site.yml`**, filtered to `site/**` and itself, with `contents: read` and the SHA-pinned actions of gsttt-site, because the root `ci.yml` runs the plugin and OpenSpec checks that a web change does not touch and the reverse. It has no deploy step. Rejected: a job in `ci.yml`, which would install the site's stack for every plugin change.

14. **English only, one route.** No documentation pages, no language switcher; the documentation site stays where it is.

## Publishing (needs Sasha's word)

Nothing here publishes the site, and nothing in the repository links to it. The recommendation is a repository of its own, `SkuratovichA/tagents-site`, that deploys the way gsttt-site does: a `deploy.yml` that only runs when started by hand, building with `SITE_BASE=/` and `SITE_DOMAIN=tagents.arstoien.com`. A second GitHub Pages site in this repository is not possible, because the project's Pages site is the VitePress documentation and publishing the site there would replace it. `site/` is self-contained, so a repository can be made from it with its history:

```sh
git subtree split --prefix=site -b site-only
git push git@github.com:SkuratovichA/tagents-site.git site-only:main
```

The domain is a CNAME record `tagents` for `arstoien.com` pointing at `skuratovicha.github.io`, at whoever hosts the DNS of `arstoien.com`, and the repository's Pages settings need `tagents.arstoien.com` as the custom domain with HTTPS enforced. None of it has been done.

## Open questions for Sasha

1. Keep the Pikachu artwork or replace it? The picture comes from https://mystickermania.com/sticker-packs/memes/surprised-pikachu and the character belongs to The Pokémon Company; the footer says the site is an unaffiliated fan tribute. Replacing it is a change to `site/src/mascot/` and `site/public/mascot/` only.
2. Where and when to publish: a separate `SkuratovichA/tagents-site` repository on `tagents.arstoien.com` as recommended, or something else?
3. The repository has no licence file, so the page says nothing about one. Should it, once there is one?
