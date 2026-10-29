import { describe, expect, it } from 'vitest'
import { parseLine, parseScreen } from './ansi.ts'

const ESC = String.fromCharCode(27)
const sgr = (codes: string) => `${ESC}[${codes}m`

describe('parseLine', () => {
  it('keeps plain text as one run in the default style', () => {
    expect(parseLine('agents> ready')).toEqual([{ text: 'agents> ready', style: {} }])
  })

  it('drops the plain spaces at the end of the line', () => {
    expect(parseLine('abc   ')).toEqual([{ text: 'abc', style: {} }])
    expect(parseLine('   ')).toEqual([])
  })

  it('reads the colours of the theme, the 256 palette and true colour', () => {
    expect(
      parseLine(`${sgr('31')}a${sgr('0')}${sgr('38;5;203')}b${sgr('0')}${sgr('38;2;1;2;3')}c`),
    ).toEqual([
      { text: 'a', style: { fg: '#f38ba8' } },
      { text: 'b', style: { fg: '#ff5f5f' } },
      { text: 'c', style: { fg: '#010203' } },
    ])
  })

  it('reads bold, italic, underline and a background', () => {
    expect(parseLine(`${sgr('1;3;4;44')}x`)).toEqual([
      { text: 'x', style: { bg: '#89b4fa', b: true, i: true, u: true } },
    ])
  })

  it('joins neighbours that end up in the same style', () => {
    expect(parseLine(`ab${sgr('0')}cd${sgr('39')}ef`)).toEqual([{ text: 'abcdef', style: {} }])
  })

  it('swaps the colours of reverse video, with the terminal colours for what was not set', () => {
    expect(parseLine(`${sgr('7')}x`)).toEqual([
      { text: 'x', style: { fg: '#1e1e2e', bg: '#cdd6f4' } },
    ])
    expect(parseLine(`${sgr('31;7')}x`)).toEqual([
      { text: 'x', style: { fg: '#1e1e2e', bg: '#f38ba8' } },
    ])
  })

  it('moves faint text towards the background, because a style has no faint flag', () => {
    const [run] = parseLine(`${sgr('2')}x`)
    expect(run?.style.fg).toMatch(/^#[0-9a-f]{6}$/)
    expect(run?.style.fg).not.toBe('#cdd6f4')
  })

  it('refuses what it cannot draw instead of guessing', () => {
    expect(() => parseLine(`${sgr('5')}x`)).toThrow(/unknown SGR code 5/)
    expect(() => parseLine(`${sgr('38;9')}x`)).toThrow(/unknown colour mode/)
    expect(() => parseLine(`${sgr('38;5;256')}x`)).toThrow(/256-colour palette/)
    expect(() => parseLine(`${sgr('48;5;300')}x`)).toThrow(/256-colour palette/)
    expect(() => parseLine(`${sgr('38;5')}x`)).toThrow(/missing/)
    expect(() => parseLine(`${sgr('38;2;300;0;0')}x`)).toThrow(/not a colour channel/)
    expect(() => parseLine(`${sgr('48;2;1;2')}x`)).toThrow(/missing/)
    expect(() => parseLine(`${ESC}[2Jx`)).toThrow(/not SGR/)
    expect(() => parseLine('日本')).toThrow(/wide character/)
  })
})

describe('parseScreen', () => {
  it('is one entry per line and ignores the newline that ends the output', () => {
    expect(parseScreen('one\n\ntwo\n')).toEqual([
      [{ text: 'one', style: {} }],
      [],
      [{ text: 'two', style: {} }],
    ])
  })
})
