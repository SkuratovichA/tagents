import { describe, expect, it } from 'vitest'
import { notFoundHead, pageHead } from './head'

describe('pageHead', () => {
  it('names no address and no image before the site has a domain', () => {
    const { meta, links } = pageHead('Title', 'About', null)
    expect(links).toEqual([])
    expect(meta).toContainEqual({ title: 'Title' })
    expect(meta).toContainEqual({ name: 'description', content: 'About' })
    expect(JSON.stringify(meta)).not.toMatch(/og:url|og:image|twitter/)
  })

  it('names its own address and the preview image once there is a domain', () => {
    const { meta, links } = pageHead('Title', 'About', 'https://example.test')
    expect(links).toEqual([{ rel: 'canonical', href: 'https://example.test/' }])
    expect(meta).toContainEqual({ property: 'og:url', content: 'https://example.test/' })
    expect(meta).toContainEqual({
      property: 'og:image',
      content: 'https://example.test/mascot/social.png',
    })
  })

  it('has no origin in the tests, as in a build without a domain', () => {
    expect(pageHead('Title', 'About').links).toEqual([])
  })
})

describe('notFoundHead', () => {
  it('asks to be left out of search results and names no address of its own, whatever the domain', () => {
    const { meta, links } = notFoundHead('https://example.test')
    expect(meta).toContainEqual({ name: 'robots', content: 'noindex' })
    expect(links).toEqual([])
    expect(JSON.stringify(meta)).not.toMatch(/og:url/)
    expect(JSON.stringify([meta, links])).not.toMatch(/canonical|https:\/\/example\.test\/"/)
  })

  it('is titled as a missing page', () => {
    expect(notFoundHead(null).meta).toContainEqual({ title: 'Page not found: tagents' })
  })
})
