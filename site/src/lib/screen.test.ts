import { describe, expect, it } from 'vitest'
import { applyFrame, screenAt, styleSheet } from './screen'
import type { Scene } from './screen'

const scene: Scene = {
  id: 'demo',
  cols: 10,
  rows: 3,
  styles: [{}, { fg: '#ff0000', b: true }, { bg: '#00ff00', i: true, u: true }],
  frames: [
    {
      t: 0,
      rows: [
        [0, [['a', 0]]],
        [1, [['b', 1]]],
        [2, []],
      ],
    },
    { t: 100, rows: [[1, [['c', 2]]]] },
  ],
}

describe('applyFrame', () => {
  it('replaces only the rows the frame names and leaves its input alone', () => {
    const before = [[['a', 0]], [['b', 1]]] as const
    expect(applyFrame(before, { t: 0, rows: [[1, [['c', 2]]]] })).toEqual([[['a', 0]], [['c', 2]]])
    expect(before[1]).toEqual([['b', 1]])
  })
})

describe('screenAt', () => {
  it('is the last frame by default', () => {
    expect(screenAt(scene)).toEqual([[['a', 0]], [['c', 2]], []])
  })

  it('is every frame up to the one asked for, applied in order', () => {
    expect(screenAt(scene, 0)).toEqual([[['a', 0]], [['b', 1]], []])
  })

  it('starts from blank rows', () => {
    expect(screenAt({ ...scene, frames: [] })).toEqual([[], [], []])
  })
})

describe('styleSheet', () => {
  it('writes one class per style that sets something, under the scope', () => {
    expect(styleSheet('.demo', scene.styles)).toBe(
      '.demo .s1{color:#ff0000;font-weight:700}.demo .s2{background:#00ff00;font-style:italic;text-decoration:underline}',
    )
  })
})
