import { afterEach, describe, expect, it, vi } from 'vitest'
import { MOUNTS } from '../../build/links.ts'

afterEach(() => {
  vi.unstubAllEnvs()
  vi.resetModules()
})

async function docsUrlUnder(base: string): Promise<string> {
  vi.stubEnv('BASE_URL', base)
  vi.resetModules()
  return (await import('./site')).DOCS_URL
}

describe('the link to the documentation', () => {
  it('leads to the documentation under the base of the site', async () => {
    expect(await docsUrlUnder('/x/')).toBe('/x/docs/')
    expect(await docsUrlUnder('/')).toBe('/docs/')
  })

  it('lies in a directory that the link check treats as built by another tool', async () => {
    const url = await docsUrlUnder('/x/')
    expect(MOUNTS.map((mount) => `/x/${mount}`)).toContain(url)
  })
})
