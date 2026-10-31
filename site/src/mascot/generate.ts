// Regenerates everything the mascot is made of from the two pictures in source/:
//
//   pnpm mascot
//
// It writes src/mascot/pikachu.ts, the sprite the hero draws, and the icons in public/mascot/, which are that sprite on the empty plate of source/plate.png. It needs ImageMagick (`magick`) on the PATH. To swap the mascot, replace the two pictures in source/ (and the colours below, if the new picture has others), run the command and commit the result.
import { execFileSync } from 'node:child_process'
import { writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { hexToRgb } from '../lib/color.ts'
import { runsOf } from '../lib/pixels.ts'

const here = import.meta.dirname
const source = resolve(here, 'source')
const publicDir = resolve(here, '..', '..', 'public', 'mascot')

/** The sprite's width in pixels; the height follows from the picture's own proportions. */
const COLUMNS = 48

const LETTERS = ['K', 'E', 'Y', 'S', 'H', 'C', 'T', 'W'] as const

type Letter = (typeof LETTERS)[number]

/** One letter per colour, sampled from source/pikachu.png. `satisfies` makes the list above and this table name the same letters. */
const COLORS = {
  K: '#3a0d04', // outline
  E: '#7c1b01', // eyes, nose, ear tips
  Y: '#f6b828', // fur
  S: '#cc8e11', // shade on the left of the face
  H: '#fdca5e', // highlight on the right of the face
  C: '#d5430f', // cheeks
  T: '#fa6f4b', // mouth
  W: '#f0e0e2', // shine of the eyes
} as const satisfies Record<Letter, string>

/** The share of a cell that has to be outline for the cell to be outline: on the silhouette a thin line must survive the shrinking, inside it only a cell that is mostly line is. */
const OUTLINE_SHARE_AT_EDGE = 0.14
const OUTLINE_SHARE_INSIDE = 0.45
/** The share of eye brown (outline included, inside the face) that makes a cell eye brown. */
const EYE_SHARE = 0.25
const SHINE_SHARE = 0.15
/** A cell is part of the sprite when at least this share of it is picture and not background. */
const COVERAGE = 0.45

interface Picture {
  width: number
  height: number
  rgba: Uint8Array
}

function magick(args: string[], input?: Uint8Array): Buffer {
  return execFileSync('magick', args, { maxBuffer: 1 << 28, input })
}

function readPicture(file: string): Picture {
  const [width = 0, height = 0] = magick([file, '-trim', '+repage', '-format', '%w %h', 'info:'])
    .toString()
    .split(' ')
    .map(Number)
  return { width, height, rgba: magick([file, '-trim', '+repage', '-depth', '8', 'rgba:-']) }
}

function pixelAt({ rgba, width }: Picture, x: number, y: number) {
  const index = (y * width + x) * 4
  return {
    r: rgba[index] ?? 0,
    g: rgba[index + 1] ?? 0,
    b: rgba[index + 2] ?? 0,
    a: rgba[index + 3] ?? 0,
  }
}

/** The pixels of the sticker's white border: transparent or near-white ones that touch the picture's edge. The shine inside an eye is white too, and is not reached from the edge. */
function backgroundOf(picture: Picture): Uint8Array {
  const { width, height } = picture
  const background = new Uint8Array(width * height)
  const isWhite = (x: number, y: number) => {
    const { r, g, b, a } = pixelAt(picture, x, y)
    return a < 200 || (r > 225 && g > 225 && b > 225)
  }
  const pending: [number, number][] = []
  for (let x = 0; x < width; x++) pending.push([x, 0], [x, height - 1])
  for (let y = 0; y < height; y++) pending.push([0, y], [width - 1, y])
  for (let next = pending.pop(); next !== undefined; next = pending.pop()) {
    const [x, y] = next
    if (x < 0 || y < 0 || x >= width || y >= height || background[y * width + x] === 1) continue
    if (!isWhite(x, y)) continue
    background[y * width + x] = 1
    pending.push([x - 1, y], [x + 1, y], [x, y - 1], [x, y + 1])
  }
  return background
}

function nearestLetter(r: number, g: number, b: number): Letter {
  let best: Letter = 'Y'
  let bestDistance = Infinity
  for (const letter of LETTERS) {
    const [pr, pg, pb] = hexToRgb(COLORS[letter])
    const distance = (r - pr) ** 2 + (g - pg) ** 2 + (b - pb) ** 2
    if (distance < bestDistance) {
      bestDistance = distance
      best = letter
    }
  }
  return best
}

interface Cell {
  covered: boolean
  share: Partial<Record<Letter, number>>
}

/** Shrinks the picture to a grid of cells, each with the share of its picture pixels that are nearest to each colour. */
function cellsOf(picture: Picture, background: Uint8Array): Cell[][] {
  const { width, height } = picture
  const size = width / COLUMNS
  const rows = Math.round(height / size)
  return Array.from({ length: rows }, (_, gy) =>
    Array.from({ length: COLUMNS }, (_, gx): Cell => {
      const counts: Partial<Record<Letter, number>> = {}
      let covered = 0
      let total = 0
      const yEnd = Math.min(height, Math.floor((gy + 1) * size))
      const xEnd = Math.min(width, Math.floor((gx + 1) * size))
      for (let y = Math.floor(gy * size); y < yEnd; y++) {
        for (let x = Math.floor(gx * size); x < xEnd; x++) {
          total++
          if (background[y * width + x] === 1) continue
          covered++
          const { r, g, b } = pixelAt(picture, x, y)
          const letter = nearestLetter(r, g, b)
          counts[letter] = (counts[letter] ?? 0) + 1
        }
      }
      const share: Partial<Record<Letter, number>> = {}
      for (const letter of LETTERS) share[letter] = (counts[letter] ?? 0) / Math.max(covered, 1)
      return { covered: covered / total >= COVERAGE, share }
    }),
  )
}

function letterOf(cell: Cell, onEdge: boolean): Letter {
  const share = (letter: Letter) => cell.share[letter] ?? 0
  if (share('K') >= (onEdge ? OUTLINE_SHARE_AT_EDGE : OUTLINE_SHARE_INSIDE)) return 'K'
  if (share('W') >= SHINE_SHARE) return 'W'
  if (share('E') + (onEdge ? 0 : share('K')) >= EYE_SHARE) return 'E'
  const fills = LETTERS.filter((letter) => letter !== 'K' && letter !== 'E' && letter !== 'W')
  return fills.reduce((best, letter) => (share(letter) > share(best) ? letter : best), 'Y')
}

/** The sprite as rows of text: one letter per colour and "." for nothing. */
export function spriteRows(sourceFile: string): string[] {
  const picture = readPicture(sourceFile)
  const cells = cellsOf(picture, backgroundOf(picture))
  const covered = (gx: number, gy: number) => cells[gy]?.[gx]?.covered ?? false
  return cells.map((row, gy) =>
    row
      .map((cell, gx) => {
        if (!cell.covered) return '.'
        const onEdge = [
          [0, 1],
          [0, -1],
          [1, 0],
          [-1, 0],
        ].some(([dx = 0, dy = 0]) => !covered(gx + dx, gy + dy))
        return letterOf(cell, onEdge)
      })
      .join(''),
  )
}

function writeSprite(rows: readonly string[]): void {
  const colors = Object.entries(COLORS)
    .map(([letter, hex]) => `  ${letter}: '${hex}',`)
    .join('\n')
  const lines = rows.map((row) => `  '${row}',`).join('\n')
  writeFileSync(
    resolve(here, 'pikachu.ts'),
    `// Generated by src/mascot/generate.ts from source/pikachu.png. Do not edit by hand: run \`pnpm mascot\`.

/** One letter per colour. */
export const PIKACHU_COLORS = {
${colors}
} as const

/** The sprite as rows of text: one letter per colour in PIKACHU_COLORS and "." for nothing. */
export const PIKACHU_ROWS: readonly string[] = [
${lines}
]
`,
  )
}

/** The sprite as raw RGBA bytes, one pixel per letter, with "." left transparent. */
function spritePixels(rows: readonly string[], width: number): Uint8Array {
  const pixels = new Uint8Array(width * rows.length * 4)
  for (const letter of LETTERS) {
    const [r, g, b] = hexToRgb(COLORS[letter])
    for (const { x, y, length } of runsOf(rows, letter))
      for (let i = 0; i < length; i++) pixels.set([r, g, b, 255], (y * width + x + i) * 4)
  }
  return pixels
}

/** Each icon at the size a browser asks for, and how many icon pixels make one side of a sprite pixel: a whole number, so that the sprite's edges stay sharp. */
const ICONS = [
  { file: 'favicon-64.png', size: 64, scale: 1, flatten: false },
  // iOS paints transparency black, so the touch icon is the plate on the plate's own colour.
  { file: 'apple-touch-icon.png', size: 180, scale: 3, flatten: true },
  // The picture a link preview shows.
  { file: 'social.png', size: 512, scale: 6, flatten: false },
] as const

/** The icons are the sprite in the middle of the plate from source/plate.png. */
function writeIcons(rows: readonly string[]): void {
  const width = Math.max(...rows.map((row) => row.length))
  const pixels = spritePixels(rows, width)
  for (const { file, size, scale, flatten } of ICONS) {
    magick(
      [
        resolve(source, 'plate.png'),
        // A plate that holds only greys is read as a grey picture, and the sprite drawn on it would turn grey too.
        '-colorspace',
        'sRGB',
        '-filter',
        'Lanczos',
        '-resize',
        `${size}x${size}`,
        '(',
        '-size',
        `${width}x${rows.length}`,
        '-depth',
        '8',
        'rgba:-',
        '-sample',
        `${scale * 100}%`,
        ')',
        '-gravity',
        'center',
        '-composite',
        ...(flatten ? ['-background', '#f7f7f7', '-alpha', 'remove', '-alpha', 'off'] : []),
        resolve(publicDir, file),
      ],
      pixels,
    )
  }
}

if (import.meta.main) {
  const rows = spriteRows(resolve(source, 'pikachu.png'))
  writeSprite(rows)
  writeIcons(rows)
  console.log(
    'mascot: src/mascot/pikachu.ts and public/mascot/{favicon-64,apple-touch-icon,social}.png',
  )
}
