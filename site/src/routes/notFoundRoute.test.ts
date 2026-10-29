import { afterEach, describe, expect, it, vi } from 'vitest'
import { Route, notFoundRouteHead } from './$'

describe('the route every unknown address lands on', () => {
  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('registers the head of the 404 page, which names no canonical link and no og:url even with a domain set', () => {
    vi.stubGlobal('__SITE_ORIGIN__', 'https://example.test')
    expect(Route.options.head).toBe(notFoundRouteHead)
    const { meta, links } = notFoundRouteHead()
    expect(meta).toContainEqual({ name: 'robots', content: 'noindex' })
    expect(links).toEqual([])
    expect(JSON.stringify(meta)).not.toMatch(/og:url/)
  })
})
