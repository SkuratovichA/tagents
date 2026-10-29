import { describe, expect, it } from 'vitest'
import { MOUNTS } from '../../build/links.ts'
import { DOCS_URL } from './site'

describe('the link to the documentation', () => {
  it('leads to the documentation under the base of the site', () => {
    expect(DOCS_URL).toBe(`${import.meta.env.BASE_URL}docs/`)
  })

  it('lies in a directory that the link check treats as built by another tool', () => {
    expect(MOUNTS.map((mount) => `${import.meta.env.BASE_URL}${mount}`)).toContain(DOCS_URL)
  })
})
