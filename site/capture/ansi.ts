import type { Style } from '../src/lib/screen.ts'
import { TERMINAL } from '../src/lib/screen.ts'
import { paletteColor } from './theme.ts'

/** Some text drawn in one style. */
export interface StyledText {
  readonly text: string
  readonly style: Style
}

interface Pen {
  fg?: string
  bg?: string
  bold: boolean
  dim: boolean
  italic: boolean
  underline: boolean
  reverse: boolean
}

const FRESH: Pen = { bold: false, dim: false, italic: false, underline: false, reverse: false }

/** `from` moved `share` of the way to `to`; both `#rrggbb`. */
function mix(from: string, to: string, share: number): string {
  const channels = (color: string) =>
    [1, 3, 5].map((at) => Number.parseInt(color.slice(at, at + 2), 16))
  const [a, b] = [channels(from), channels(to)]
  const mixed = a.map((channel, at) => Math.round(channel + ((b[at] ?? 0) - channel) * share))
  return `#${mixed.map((channel) => channel.toString(16).padStart(2, '0')).join('')}`
}

/** The style a pen draws with: reverse video swaps the colours and faint text is moved towards the background, because a style has neither flag. */
function styleOf(pen: Pen): Style {
  let fg = pen.fg
  let bg = pen.bg
  if (pen.reverse) [fg, bg] = [bg ?? TERMINAL.bg, fg ?? TERMINAL.fg]
  if (pen.dim) fg = mix(fg ?? TERMINAL.fg, bg ?? TERMINAL.bg, 0.45)
  return {
    ...(fg !== undefined && fg !== TERMINAL.fg && { fg }),
    ...(bg !== undefined && bg !== TERMINAL.bg && { bg }),
    ...(pen.bold && { b: true as const }),
    ...(pen.italic && { i: true as const }),
    ...(pen.underline && { u: true as const }),
  }
}

/** Applies the codes of one SGR sequence to `pen`. */
function applySgr(pen: Pen, codes: readonly number[]): void {
  for (let at = 0; at < codes.length; at++) {
    const code = codes[at] ?? 0
    if (code === 0) Object.assign(pen, FRESH, { fg: undefined, bg: undefined })
    else if (code === 1) pen.bold = true
    else if (code === 2) pen.dim = true
    else if (code === 3) pen.italic = true
    else if (code === 4) pen.underline = true
    else if (code === 7) pen.reverse = true
    else if (code === 22) Object.assign(pen, { bold: false, dim: false })
    else if (code === 23) pen.italic = false
    else if (code === 24) pen.underline = false
    else if (code === 27) pen.reverse = false
    else if (code >= 30 && code <= 37) pen.fg = paletteColor(code - 30)
    else if (code >= 90 && code <= 97) pen.fg = paletteColor(code - 90 + 8)
    else if (code >= 40 && code <= 47) pen.bg = paletteColor(code - 40)
    else if (code >= 100 && code <= 107) pen.bg = paletteColor(code - 100 + 8)
    else if (code === 39) pen.fg = undefined
    else if (code === 49) pen.bg = undefined
    else if (code === 38 || code === 48) {
      const target = code === 38 ? 'fg' : 'bg'
      const mode = codes[at + 1]
      if (mode === 5) {
        pen[target] = paletteColor(codes[at + 2] ?? 0)
        at += 2
      } else if (mode === 2) {
        const [r = 0, g = 0, b = 0] = codes.slice(at + 2, at + 5)
        pen[target] =
          `#${[r, g, b].map((channel) => channel.toString(16).padStart(2, '0')).join('')}`
        at += 4
      } else throw new Error(`unknown colour mode in SGR ${codes.join(';')}`)
    } else throw new Error(`unknown SGR code ${code}`)
  }
}

const ESC = String.fromCharCode(27)
const SGR = new RegExp(`${ESC}\\[([0-9;:]*)m`, 'g')

// A character the terminal draws two cells wide would move every column after it.
const WIDE = /[ᄀ-ᅟ⺀-꓏가-힣豈-﫿︰-﹯＀-｠￠-￦]|\p{Emoji_Presentation}/u

/** One line of `tmux capture-pane -e -p` as runs of text: neighbours in the same style are one run and a tail of plain spaces is dropped. */
export function parseLine(line: string): StyledText[] {
  const pen: Pen = { ...FRESH }
  const runs: StyledText[] = []
  const push = (text: string) => {
    if (text === '') return
    if (WIDE.test(text))
      throw new Error(`a wide character would break the columns: ${JSON.stringify(text)}`)
    const style = styleOf(pen)
    const last = runs.at(-1)
    if (last && JSON.stringify(last.style) === JSON.stringify(style))
      runs[runs.length - 1] = { text: last.text + text, style }
    else runs.push({ text, style })
  }
  let from = 0
  for (const match of line.matchAll(SGR)) {
    push(line.slice(from, match.index))
    const codes = match[1] === '' ? [0] : (match[1] ?? '').split(/[;:]/).map(Number)
    applySgr(pen, codes)
    from = match.index + match[0].length
  }
  push(line.slice(from))
  for (const run of runs)
    if (run.text.includes(ESC))
      throw new Error(`an escape sequence that is not SGR: ${JSON.stringify(run.text)}`)
  const tail = runs.at(-1)
  if (tail && Object.keys(tail.style).length === 0) {
    const trimmed = tail.text.trimEnd()
    if (trimmed === '') runs.pop()
    else runs[runs.length - 1] = { text: trimmed, style: tail.style }
  }
  return runs
}

/** The screen `tmux capture-pane -e -p` printed, one entry per line. */
export function parseScreen(output: string): StyledText[][] {
  return output.replace(/\n$/, '').split('\n').map(parseLine)
}
