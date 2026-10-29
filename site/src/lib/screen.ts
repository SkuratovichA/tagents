/** A terminal screen as the site stores it: styled runs of text per row, and the frames of a recording as the rows that changed. The browser reads it; `capture/` writes it. */

/** The colours of a cell that the terminal's own defaults do not give; `#rrggbb`. */
export interface Style {
  readonly fg?: string
  readonly bg?: string
  readonly b?: true
  readonly i?: true
  readonly u?: true
}

/** The terminal's own colours, the ones a cell without a colour of its own has. */
export const TERMINAL = { fg: '#cdd6f4', bg: '#1e1e2e' } as const

/** Some text and the index of its style in `Scene.styles`. */
export type Run = readonly [text: string, style: number]

export type Row = readonly Run[]

export interface Frame {
  /** Milliseconds since the start of the recording. */
  readonly t: number
  /** The rows that differ from the frame before, by row number; the first frame has every row. */
  readonly rows: readonly (readonly [row: number, content: Row])[]
}

export interface Scene {
  readonly id: string
  readonly cols: number
  readonly rows: number
  /** Index 0 is the terminal's default style. */
  readonly styles: readonly Style[]
  readonly frames: readonly Frame[]
}

/** The screen after `frame` was put on top of `screen`. */
export function applyFrame(screen: readonly Row[], frame: Frame): Row[] {
  const next = [...screen]
  for (const [row, content] of frame.rows) next[row] = content
  return next
}

/** The screen of frame `index` (the last one when left out): every frame before it, applied in order. */
export function screenAt(scene: Scene, index: number = scene.frames.length - 1): Row[] {
  const empty: Row[] = Array.from({ length: scene.rows }, () => [])
  return scene.frames.slice(0, index + 1).reduce(applyFrame, empty)
}

/** The CSS of the styles of a scene: `.s<index>` classes under `scope`. */
export function styleSheet(scope: string, styles: readonly Style[]): string {
  return styles
    .map((style, index) => {
      const rules = [
        style.fg && `color:${style.fg}`,
        style.bg && `background:${style.bg}`,
        style.b && 'font-weight:700',
        style.i && 'font-style:italic',
        style.u && 'text-decoration:underline',
      ].filter(Boolean)
      return rules.length > 0 ? `${scope} .s${index}{${rules.join(';')}}` : ''
    })
    .join('')
}
