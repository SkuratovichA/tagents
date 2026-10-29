import { describe, expect, it } from 'vitest'
import { runsOf } from './pixels'

describe('runsOf', () => {
  it('finds the runs of one letter, row by row and left to right', () => {
    expect(runsOf(['.##.#', 'KK#..', '...'], '#')).toEqual([
      { x: 1, y: 0, length: 2 },
      { x: 4, y: 0, length: 1 },
      { x: 2, y: 1, length: 1 },
    ])
  })

  it('reads a letter that is special in a regular expression as itself', () => {
    expect(runsOf(['.##..', 'K.K'], '.')).toEqual([
      { x: 0, y: 0, length: 1 },
      { x: 3, y: 0, length: 2 },
      { x: 1, y: 1, length: 1 },
    ])
  })
})
