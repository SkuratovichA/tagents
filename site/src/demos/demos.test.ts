import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import { DEMO_COPY } from '../content'
import { screenAt } from '../lib/screen'
import type { Row, Scene } from '../lib/screen'
import { DEMOS } from '.'

const GLYPHS = new Set(
  readFileSync(resolve(import.meta.dirname, '../../public/fonts/glyphs.txt'), 'utf8').trimEnd(),
)
const COLOUR = /^#[0-9a-f]{6}$/
const textOf = (row: Row) => row.map(([text]) => text).join('')

describe.each(DEMOS.map((scene) => [scene.id, scene] as const))(
  'the %s recording',
  (_id, scene: Scene) => {
    it('has a style table whose first entry is the terminal default and whose colours are hex', () => {
      expect(scene.styles[0]).toEqual({})
      for (const { fg, bg } of scene.styles) {
        if (fg !== undefined) expect(fg).toMatch(COLOUR)
        if (bg !== undefined) expect(bg).toMatch(COLOUR)
      }
    })

    it('starts with every row and then only names rows and styles that exist', () => {
      const [first, ...later] = scene.frames
      expect(first?.rows.map(([row]) => row)).toEqual(
        Array.from({ length: scene.rows }, (_, row) => row),
      )
      for (const frame of scene.frames) {
        const named = frame.rows.map(([row]) => row)
        expect(named).toEqual([...new Set(named)].sort((a, b) => a - b))
        for (const [row, content] of frame.rows) {
          expect(row).toBeLessThan(scene.rows)
          for (const [text, style] of content) {
            expect(text).not.toBe('')
            expect(style).toBeLessThan(scene.styles.length)
          }
        }
      }
      expect(later.length).toBeGreaterThan(0)
    })

    it('moves forward in time and ends within a quarter of a minute', () => {
      const times = scene.frames.map(({ t }) => t)
      expect(times).toEqual([...times].sort((a, b) => a - b))
      expect(new Set(times).size).toBe(times.length)
      expect(times[0]).toBeGreaterThanOrEqual(0)
      expect(times.at(-1)).toBeLessThanOrEqual(15_000)
    })

    it('never draws a row wider than the screen, in glyphs the font has', () => {
      for (let index = 0; index < scene.frames.length; index++)
        for (const row of screenAt(scene, index)) {
          const text = textOf(row)
          expect(Array.from(text).length).toBeLessThanOrEqual(scene.cols)
          for (const char of text)
            expect(GLYPHS.has(char), `${JSON.stringify(char)} is not in the font`).toBe(true)
        }
    })

    it('shows the dashboard on its last frame, with nothing of the machine it was recorded on', () => {
      const screen = screenAt(scene).map(textOf).join('\n')
      expect(screen).toContain('agents>')
      expect(JSON.stringify(scene)).not.toMatch(/\/Users\/|\/tmp\/|\/home\//)
    })
  },
)

describe('the recordings', () => {
  it('are the ones the page asks for, each once', () => {
    const ids = DEMOS.map(({ id }) => id)
    expect(new Set(ids).size).toBe(ids.length)
    expect(DEMO_COPY.map(({ scene }) => scene).sort()).toEqual([...ids].sort())
  })

  it('end where their captions say they do', () => {
    const last = (id: string) => {
      const scene = DEMOS.find((candidate) => candidate.id === id)
      return scene ? screenAt(scene).map(textOf).join('\n') : ''
    }
    expect(last('hero')).toContain('Do you want to proceed?')
    expect(last('keys')).toContain('every key — enter runs the one you pick')
    expect(last('new-chat')).toContain('New chat')
    expect(last('closed')).toContain('Session resumed')
  })
})
