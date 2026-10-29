// Pixel art as rows of text: "#" is a filled pixel, anything else is empty.

export const SUN: readonly string[] = [
  '....#....',
  '.#..#..#.',
  '...###...',
  '..#####..',
  '#.#####.#',
  '..#####..',
  '...###...',
  '.#..#..#.',
  '....#....',
]

export const MOON: readonly string[] = [
  '...####..',
  '..###....',
  '.###.....',
  '.###.....',
  '.###.....',
  '.###.....',
  '..###...#',
  '...######',
  '....####.',
]

/** A run of one letter in a row of pixel art: where it starts and how many pixels long it is. */
export interface Run {
  x: number
  y: number
  length: number
}

/** The runs of `letter` in rows of pixel art, row by row and left to right. Any character can be the letter, "." included. */
export function runsOf(rows: readonly string[], letter: string): Run[] {
  return rows.flatMap((row, y) =>
    Array.from(row.matchAll(/(.)\1*/g))
      .filter((match) => match[1] === letter)
      .map((match) => ({ x: match.index, y, length: match[0].length })),
  )
}
