import { describe, expect, it } from 'vitest'
import { absoluteUrl, buildRobots, buildSitemap, pagePath, sitemapUrls } from './outputs.ts'
import { readSiteConfig } from './site-config.ts'

const files = [
  '.nojekyll',
  '404.html',
  'assets/app-1a2b3c.js',
  'favicon.svg',
  'index.html',
  'mascot/plate.png',
]

describe('pagePath', () => {
  it.each<[string, string | null]>([
    ['index.html', '/'],
    ['404.html', null],
    ['assets/app-1a2b3c.js', null],
  ])('maps %s to %j', (file, expected) => {
    expect(pagePath(file)).toBe(expected)
  })

  it('keeps a 404 folder page out of the sitemap too', () => {
    expect(pagePath('404/index.html')).toBeNull()
  })
})

describe('sitemapUrls', () => {
  it('lists the page under the base path and the domain', () => {
    const site = readSiteConfig({ SITE_BASE: '/tagents-site/', SITE_DOMAIN: 'tagents.example.org' })
    expect(sitemapUrls(files, site)).toEqual(['https://tagents.example.org/tagents-site/'])
  })

  it('is empty while the site has no domain, since there is no origin to build addresses on', () => {
    expect(sitemapUrls(files, readSiteConfig({}))).toEqual([])
    expect(absoluteUrl(readSiteConfig({}), 'sitemap.xml')).toBeNull()
  })
})

describe('buildSitemap and buildRobots', () => {
  it('writes one escaped <loc> per url', () => {
    const xml = buildSitemap(['https://example.invalid/a?x=1&y=2'])
    expect(xml).toContain('<loc>https://example.invalid/a?x=1&amp;y=2</loc>')
    expect(xml.startsWith('<?xml')).toBe(true)
  })

  it('points robots.txt at the sitemap when there is one', () => {
    const site = readSiteConfig({ SITE_DOMAIN: 'tagents.example.org' })
    expect(buildRobots(absoluteUrl(site, 'sitemap.xml'))).toBe(
      'User-agent: *\nAllow: /\n\nSitemap: https://tagents.example.org/sitemap.xml\n',
    )
  })

  it('lets crawlers in and names no sitemap when there is none', () => {
    expect(buildRobots(null)).toBe('User-agent: *\nAllow: /\n')
  })
})
