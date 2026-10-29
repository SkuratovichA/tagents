// Writes the font the demo terminals are drawn in:
//
//   pnpm font
//
// It cuts DejaVu Sans Mono down to the characters the demos use (and printable ASCII), once for the regular and once for the bold weight, into public/fonts/. A terminal needs one font for all its cells: the box drawing, the block bars and the state marks all have to be exactly one cell wide, and DejaVu Sans Mono is the monospaced font that has them all. It needs python3 with fonttools and brotli (`pyftsubset`), and refuses to write a font that lacks a character the demos use. Run it again after `pnpm capture`.
import { execFileSync } from 'node:child_process'
import { copyFileSync, mkdirSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { DEMOS } from '../src/demos/index.ts'

const site = resolve(import.meta.dirname, '..')
const fonts = resolve(site, 'public', 'fonts')
const source = resolve(site, 'node_modules', '@fontsource', 'dejavu-mono')

const used = new Set<string>()
for (let code = 0x20; code <= 0x7e; code++) used.add(String.fromCodePoint(code))
for (const scene of DEMOS)
  for (const frame of scene.frames)
    for (const [, row] of frame.rows)
      for (const [text] of row) for (const char of text) used.add(char)
const characters = [...used].sort().join('')

const codePointsOf = (file: string) =>
  new Set(
    execFileSync(process.env.PYTHON ?? 'python3', [
      '-I',
      '-c',
      'import sys\nfrom fontTools.ttLib import TTFont\nprint(*TTFont(sys.argv[1]).getBestCmap())',
      file,
    ])
      .toString()
      .trim()
      .split(' ')
      .map(Number),
  )

mkdirSync(fonts, { recursive: true })
for (const weight of ['400', '700']) {
  const out = resolve(fonts, `dejavu-sans-mono-${weight}.woff2`)
  execFileSync(process.env.PYFTSUBSET ?? 'pyftsubset', [
    resolve(source, 'files', `dejavu-mono-latin-${weight}-normal.woff2`),
    `--text=${characters}`,
    '--flavor=woff2',
    '--layout-features=',
    '--no-hinting',
    '--name-IDs=*',
    `--output-file=${out}`,
  ])
  const has = codePointsOf(out)
  const missing = [...used].filter((char) => !has.has(char.codePointAt(0) ?? -1))
  if (missing.length > 0)
    throw new Error(
      `${out} has no glyph for ${missing.join(' ')}: add a substitute in capture/frames.ts`,
    )
}
// the license asks for its notice to travel with the font
copyFileSync(resolve(source, 'LICENSE'), resolve(fonts, 'LICENSE-DejaVu.txt'))
writeFileSync(resolve(fonts, 'glyphs.txt'), `${characters}\n`)
console.log(`fonts: ${used.size} characters in public/fonts/`)
