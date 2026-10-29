import { describe, expect, it } from 'vitest'
import { normaliseBase, readSiteConfig } from './site-config.ts'

describe('normaliseBase', () => {
  it.each<[string | undefined, string]>([
    [undefined, '/'],
    ['', '/'],
    ['/', '/'],
    ['tagents-site', '/tagents-site/'],
    ['/tagents-site', '/tagents-site/'],
    ['/tagents-site/', '/tagents-site/'],
    ['/docs/site/', '/docs/site/'],
  ])('turns %j into %s', (raw, expected) => {
    expect(normaliseBase(raw)).toBe(expected)
  })

  it.each(['/a b/', '/a//b/', '/../x/', '/a?b', '/a#b'])('rejects %j', (raw) => {
    expect(() => normaliseBase(raw)).toThrow(/SITE_BASE/)
  })
})

describe('readSiteConfig', () => {
  it('serves from the root with no domain and no origin by default', () => {
    expect(readSiteConfig({})).toEqual({ base: '/', domain: null, origin: null })
  })

  it('treats empty values like unset ones, as a deploy workflow passes them', () => {
    expect(readSiteConfig({ SITE_BASE: '', SITE_DOMAIN: '' })).toEqual(readSiteConfig({}))
  })

  it('keeps the base without a domain and still has no origin', () => {
    expect(readSiteConfig({ SITE_BASE: '/tagents-site/' })).toEqual({
      base: '/tagents-site/',
      domain: null,
      origin: null,
    })
  })

  it('builds absolute URLs on the custom domain and keeps the base', () => {
    expect(
      readSiteConfig({ SITE_BASE: '/tagents-site/', SITE_DOMAIN: 'TAGENTS.example.org' }),
    ).toEqual({
      base: '/tagents-site/',
      domain: 'tagents.example.org',
      origin: 'https://tagents.example.org',
    })
  })

  it('rejects a domain that is not a host name', () => {
    expect(() => readSiteConfig({ SITE_DOMAIN: 'https://tagents.example.org/' })).toThrow(
      /SITE_DOMAIN/,
    )
  })
})
