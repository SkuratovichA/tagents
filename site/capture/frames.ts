import type { Frame, Row, Scene, Style } from '../src/lib/screen.ts'
import type { StyledText } from './ansi.ts'

/** The screen at `t` milliseconds into a recording. */
export interface Shot {
  readonly t: number
  readonly lines: readonly (readonly StyledText[])[]
}

/** Characters the font of the site has no glyph for, and what is drawn instead. */
const SUBSTITUTES: Readonly<Record<string, string>> = { '⎿': '└' }

const substitute = (text: string) => text.replace(/./gu, (char) => SUBSTITUTES[char] ?? char)

/** The recording as a scene: a style table, the first screen whole and each later one as the rows that changed. Shots that look like the one before are dropped. */
export function encode(id: string, cols: number, shots: readonly Shot[]): Scene {
  const styles: Style[] = [{}]
  const known = new Map<string, number>([['{}', 0]])
  const indexOf = (style: Style) => {
    const key = JSON.stringify(style)
    const found = known.get(key)
    if (found !== undefined) return found
    styles.push(style)
    known.set(key, styles.length - 1)
    return styles.length - 1
  }
  const rowsOf = (shot: Shot): Row[] =>
    shot.lines.map((line) =>
      line.map(({ text, style }) => [substitute(text), indexOf(style)] as const),
    )
  const frames: Frame[] = []
  let before: Row[] = []
  for (const shot of shots) {
    const rows = rowsOf(shot)
    const changed = rows.flatMap((row, at) =>
      JSON.stringify(row) === JSON.stringify(before[at]) ? [] : [[at, row] as const],
    )
    if (frames.length > 0 && changed.length === 0) continue
    frames.push({ t: Math.round(shot.t / 10) * 10, rows: changed })
    before = rows
  }
  return { id, cols, rows: shots[0]?.lines.length ?? 0, styles, frames }
}
