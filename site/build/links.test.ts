import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { listFiles } from './files.ts'
import {
  checkLinks,
  extractReferences,
  findRemoteCss,
  findRemoteLoads,
  resolveReference,
  servedPath,
} from './links.ts'

const BASE = '/tagents-site/'
const files = new Set([
  'index.html',
  'docs/index.html',
  'docs/a/index.html',
  'favicon.svg',
  '404.html',
])

describe('extractReferences', () => {
  it('reads href and src with either quote style and decodes entities', () => {
    const html = `<a href="/a?x=1&amp;y=2">a</a><img src='/b.png'><link rel="icon" href="#top"><p>href="no"</p>`
    expect(extractReferences(html)).toEqual(['/a?x=1&y=2', '/b.png', '#top'])
  })
})

describe('servedPath', () => {
  it.each([
    ['index.html', '/tagents-site/'],
    ['docs/a/index.html', '/tagents-site/docs/a/'],
    ['404.html', '/tagents-site/404.html'],
  ])('serves %s at %s', (file, expected) => {
    expect(servedPath(file, BASE)).toBe(expected)
  })
})

describe('resolveReference', () => {
  const resolve = (reference: string, page = 'index.html') =>
    resolveReference(reference, page, BASE, files)

  it('finds a page by its directory address, which ends in a slash', () => {
    expect(resolve('/tagents-site/docs/a/')).toMatchObject({
      kind: 'internal',
      file: 'docs/a/index.html',
    })
  })

  it('refuses the address of a page without the slash, which GitHub Pages redirects', () => {
    expect(resolve('/tagents-site/docs/a')).toEqual({
      kind: 'broken',
      reason: 'GitHub Pages redirects /tagents-site/docs/a to /tagents-site/docs/a/',
    })
    expect(resolve('a', 'docs/index.html')).toMatchObject({ kind: 'broken' })
  })

  it('finds the home page and plain files', () => {
    expect(resolve('/tagents-site/')).toMatchObject({ file: 'index.html' })
    expect(resolve('/tagents-site/favicon.svg')).toMatchObject({ file: 'favicon.svg' })
  })

  it('resolves relative references against the address of the page', () => {
    expect(resolve('../', 'docs/a/index.html')).toMatchObject({ file: 'docs/index.html' })
    expect(resolve('#main', 'docs/a/index.html')).toMatchObject({
      file: 'docs/a/index.html',
      fragment: 'main',
    })
  })

  it('leaves other hosts and schemes alone', () => {
    expect(resolve('https://github.com/SkuratovichA/tagents')).toEqual({ kind: 'external' })
    expect(resolve('mailto:someone@example.invalid')).toEqual({ kind: 'external' })
    expect(resolve('//example.invalid/x')).toEqual({ kind: 'external' })
  })

  it('reports a missing file and an address outside the base path', () => {
    expect(resolve('/tagents-site/docs/missing/')).toMatchObject({ kind: 'broken' })
    expect(resolve('/docs/a/')).toEqual({
      kind: 'broken',
      reason: `outside the base path ${BASE}`,
    })
  })
})

describe('checkLinks', () => {
  const roots: string[] = []

  afterEach(async () => {
    await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })))
  })

  async function site(pages: Record<string, string>): Promise<string> {
    const root = await mkdtemp(join(tmpdir(), 'tagents-links-'))
    roots.push(root)
    for (const [file, html] of Object.entries(pages)) {
      await mkdir(dirname(join(root, file)), { recursive: true })
      await writeFile(join(root, file), html)
    }
    return root
  }

  it('accepts a site whose links all resolve, anchors included', async () => {
    const root = await site({
      'index.html': `<main id="main"><a href="${BASE}docs/a/#intro">a</a><a href="#main">skip</a></main>`,
      'docs/a/index.html': '<h2 id="intro">Intro</h2><a href="https://example.invalid/">out</a>',
    })
    expect(await checkLinks(root, await listFiles(root), BASE)).toEqual([])
  })

  it('names the page, the reference and the reason of every broken link', async () => {
    const root = await site({
      'index.html': `<a href="${BASE}nowhere/">gone</a><a href="${BASE}docs/a/#nope">anchor</a>`,
      'docs/a/index.html': '<h2 id="intro">Intro</h2>',
    })
    const problems = await checkLinks(root, await listFiles(root), BASE)
    expect(problems).toHaveLength(2)
    expect(problems[0]).toMatchObject({ page: 'index.html', reference: `${BASE}nowhere/` })
    expect(problems[1]?.reason).toContain('"nope"')
  })

  it('reports a link to a page by the address GitHub Pages would redirect', async () => {
    const root = await site({
      'index.html': `<a href="${BASE}docs/a">a</a>`,
      'docs/a/index.html': '<h2 id="intro">Intro</h2>',
    })
    const problems = await checkLinks(root, await listFiles(root), BASE)
    expect(problems).toEqual([
      {
        page: 'index.html',
        reference: `${BASE}docs/a`,
        reason: `GitHub Pages redirects ${BASE}docs/a to ${BASE}docs/a/`,
      },
    ])
  })

  it('checks the addresses of the sitemap the same way', async () => {
    const sitemap = (...paths: string[]) =>
      `<urlset>${paths.map((path) => `<url><loc>https://example.invalid${path}</loc></url>`).join('')}</urlset>`
    const pages = { 'index.html': '', 'docs/a/index.html': '' }
    const good = await site({ ...pages, 'sitemap.xml': sitemap(BASE, `${BASE}docs/a/`) })
    expect(await checkLinks(good, await listFiles(good), BASE)).toEqual([])

    const bare = await site({ ...pages, 'sitemap.xml': sitemap(BASE, `${BASE}docs/a`) })
    const problems = await checkLinks(bare, await listFiles(bare), BASE)
    expect(problems.map((problem) => problem.page)).toEqual(['sitemap.xml'])
    expect(problems[0]?.reason).toContain('redirects')
  })
})

describe('what a page may load from another site', () => {
  const ORIGIN = 'https://tagents.example.test'

  it('finds a stylesheet link, a script, an image, a srcset and a url() or @import in a style', () => {
    const html = `<link rel="stylesheet" href="https://fonts.example.invalid/css">
      <script src="//cdn.example.invalid/a.js"></script>
      <img src="https://img.example.invalid/a.png" srcset="/a.png 1x, https://img.example.invalid/b.png 2x">
      <div style="background:url('https://img.example.invalid/c.png')"></div>
      <style>@import url(https://fonts.example.invalid/more.css); .a{background:url(https://img.example.invalid/d.png)}</style>`
    expect(findRemoteLoads(html, null)).toEqual([
      'https://fonts.example.invalid/css',
      '//cdn.example.invalid/a.js',
      'https://img.example.invalid/a.png',
      '/a.png 1x, https://img.example.invalid/b.png 2x',
      'https://img.example.invalid/c.png',
      'https://fonts.example.invalid/more.css',
      'https://img.example.invalid/d.png',
    ])
  })

  it('lets an anchor, the canonical link, the site’s own og:url and og:image, and a namespace through', () => {
    const html = `<a href="https://github.com/example/repo">out</a>
      <link rel="canonical" href="${ORIGIN}/">
      <meta property="og:url" content="${ORIGIN}/"><meta property="og:image" content="${ORIGIN}/mascot/social.png">
      <meta name="description" content="Install with https://example.invalid/install.sh">
      <svg xmlns="http://www.w3.org/2000/svg"></svg><link rel="icon" href="/favicon.png">`
    expect(findRemoteLoads(html, ORIGIN)).toEqual([])
  })

  it('does not let an og:image of another site through', () => {
    const html = '<meta property="og:image" content="https://elsewhere.example.invalid/a.png">'
    expect(findRemoteLoads(html, ORIGIN)).toEqual(['https://elsewhere.example.invalid/a.png'])
  })

  it('reads the urls of a stylesheet and leaves relative ones and data uris', () => {
    const css =
      '@import "https://fonts.example.invalid/x.css"; a{background:url(./a.woff2) url(data:image/png;base64,AAA) url("//cdn.example.invalid/b.png")}'
    expect(findRemoteCss(css)).toEqual([
      '//cdn.example.invalid/b.png',
      'https://fonts.example.invalid/x.css',
    ])
  })

  it('makes checkLinks report a font link and an @import and accept an anchor', async () => {
    const root = await mkdtemp(join(tmpdir(), 'tagents-remote-'))
    try {
      await writeFile(
        join(root, 'index.html'),
        `<link rel="stylesheet" href="https://fonts.example.invalid/css"><a href="https://github.com/example/repo">out</a>`,
      )
      await writeFile(
        join(root, 'site.css'),
        '@import url("https://fonts.example.invalid/more.css");',
      )
      const problems = await checkLinks(root, await listFiles(root), BASE)
      expect(problems).toEqual([
        {
          page: 'index.html',
          reference: 'https://fonts.example.invalid/css',
          reason: 'loads from another site',
        },
        {
          page: 'site.css',
          reference: 'https://fonts.example.invalid/more.css',
          reason: 'loads from another site',
        },
      ])
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  })
})
