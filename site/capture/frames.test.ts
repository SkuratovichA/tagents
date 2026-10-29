import { describe, expect, it } from 'vitest'
import { screenAt } from '../src/lib/screen.ts'
import type { Style } from '../src/lib/screen.ts'
import { encode } from './frames.ts'
import type { Shot } from './frames.ts'

const red: Style = { fg: '#f38ba8' }
const line = (text: string, style: Style = {}) => [{ text, style }]

const shots: Shot[] = [
  { t: 0, lines: [line('one'), line('two', red)] },
  { t: 104, lines: [line('one'), line('two', red)] },
  { t: 212, lines: [line('one'), line('2', red)] },
  { t: 304, lines: [line('uno'), line('2', red)] },
]

describe('encode', () => {
  const scene = encode('demo', 80, shots)

  it('puts the first screen whole and then only the rows that changed', () => {
    expect(scene.frames.map(({ rows }) => rows.map(([row]) => row))).toEqual([[0, 1], [1], [0]])
  })

  it('drops a shot that looks like the one before it and rounds the time to ten milliseconds', () => {
    expect(scene.frames.map(({ t }) => t)).toEqual([0, 210, 300])
  })

  it('names each style once, with the default at index 0', () => {
    expect(scene.styles).toEqual([{}, red])
  })

  it('replays to the screens it was made from', () => {
    const text = (index: number) =>
      screenAt(scene, index).map((row) => row.map(([part]) => part).join(''))
    expect([text(0), text(1), text(2)]).toEqual([
      ['one', 'two'],
      ['one', '2'],
      ['uno', '2'],
    ])
  })

  it('records the size of the screen', () => {
    expect([scene.id, scene.cols, scene.rows]).toEqual(['demo', 80, 2])
  })

  it('draws the arrow of a tool result with the box character the font has', () => {
    const arrow = encode('arrow', 10, [{ t: 0, lines: [line('⎿ ok')] }])
    expect(arrow.frames[0]?.rows[0]?.[1]).toEqual([['└ ok', 0]])
  })
})
