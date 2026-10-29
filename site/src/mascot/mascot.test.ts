import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, relative, resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import { MASCOT } from '.'
import { PIKACHU_COLORS, PIKACHU_ROWS } from './pikachu'

const site = resolve(import.meta.dirname, '../..')

function filesUnder(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name)
    return statSync(path).isDirectory() ? filesUnder(path) : [path]
  })
}

describe('the sprite', () => {
  it('is a rectangle of letters that name a colour, or a dot for nothing', () => {
    const letters = new Set(Object.keys(PIKACHU_COLORS))
    expect(new Set(PIKACHU_ROWS.map((row) => row.length)).size).toBe(1)
    for (const char of PIKACHU_ROWS.join('')) expect(char === '.' || letters.has(char)).toBe(true)
    for (const colour of Object.values(PIKACHU_COLORS)) expect(colour).toMatch(/^#[0-9a-f]{6}$/)
  })

  it('uses every colour it names', () => {
    for (const letter of Object.keys(PIKACHU_COLORS))
      expect(PIKACHU_ROWS.join('')).toContain(letter)
  })
})

describe('the credit', () => {
  it('says the mascot is a fan tribute, that the site is not affiliated, and whose trademark it is', () => {
    expect(MASCOT.credit).toMatch(/fan tribute/)
    expect(MASCOT.credit).toMatch(
      /not affiliated with Nintendo, Creatures Inc\. or GAME FREAK inc\./,
    )
    expect(MASCOT.credit).toMatch(/trademark of Nintendo, Creatures Inc\. and GAME FREAK inc\./)
  })
})

describe('the mascot directory', () => {
  const name = new RegExp(MASCOT.name, 'i')

  it('is the only place of the source that names the mascot', () => {
    const outside = filesUnder(join(site, 'src')).filter(
      (file) =>
        !relative(join(site, 'src'), file).startsWith('mascot') &&
        !/\.test\.tsx?$/.test(file) &&
        !/\.(png|woff2)$/.test(file) &&
        !file.endsWith('routeTree.gen.ts'),
    )
    expect(outside.length).toBeGreaterThan(10)
    expect(outside.filter((file) => name.test(readFileSync(file, 'utf8')))).toEqual([])
  })

  it('is the only place in public/ that holds its pictures', () => {
    const pictures = filesUnder(join(site, 'public')).filter((file) => file.endsWith('.png'))
    expect(pictures.map((file) => relative(join(site, 'public'), file)).sort()).toEqual([
      'mascot/apple-touch-icon.png',
      'mascot/favicon-64.png',
      'mascot/social.png',
    ])
  })
})
