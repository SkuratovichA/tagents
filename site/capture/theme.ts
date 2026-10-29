/** The sixteen colours of Catppuccin Mocha, the theme the screenshots in docs/images are drawn with. */
const ANSI = [
  '#45475a',
  '#f38ba8',
  '#a6e3a1',
  '#f9e2af',
  '#89b4fa',
  '#f5c2e7',
  '#94e2d5',
  '#bac2de',
  '#585b70',
  '#f38ba8',
  '#a6e3a1',
  '#f9e2af',
  '#89b4fa',
  '#f5c2e7',
  '#94e2d5',
  '#a6adc8',
] as const

const CUBE = [0, 95, 135, 175, 215, 255] as const

const hex = (r: number, g: number, b: number) =>
  `#${[r, g, b].map((channel) => channel.toString(16).padStart(2, '0')).join('')}`

/** The colour of an xterm palette index: 0-15 the theme, 16-231 the 6x6x6 cube, 232-255 the greys. */
export function paletteColor(index: number): string {
  if (!Number.isInteger(index) || index < 0 || index > 255)
    throw new Error(`${index} is not an index of the 256-colour palette`)
  const theme = ANSI[index]
  if (theme !== undefined) return theme
  if (index >= 232 && index <= 255) {
    const level = 8 + (index - 232) * 10
    return hex(level, level, level)
  }
  const cube = index - 16
  const [r = 0, g = 0, b = 0] = [Math.floor(cube / 36), Math.floor(cube / 6) % 6, cube % 6].map(
    (step) => CUBE[step] ?? 0,
  )
  return hex(r, g, b)
}
