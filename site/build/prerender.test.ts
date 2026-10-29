import { describe, expect, it } from 'vitest'
import { prerenderOptions } from './prerender.ts'

describe('the pages the prerender may write', () => {
  const kept = (base: string, ...paths: string[]) =>
    paths.filter((path) => prerenderOptions(base).filter({ path }))

  it('drops the documentation, with or without the slash, and keeps the rest', () => {
    expect(kept('/', '/', '/404', '/documents/', '/docs/', '/docs/guide/', '/docs')).toEqual([
      '/',
      '/404',
      '/documents/',
    ])
  })

  it('looks for the documentation under the base of the site', () => {
    expect(kept('/x/', '/x/docs/', '/docs/')).toEqual(['/docs/'])
  })
})
