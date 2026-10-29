import { describe, expect, it } from 'vitest'
import { hexToRgb, toHex } from './color'

describe('hexToRgb and toHex', () => {
  it('turn a colour into its channels and back', () => {
    expect(hexToRgb('#1e1e2e')).toEqual([30, 30, 46])
    expect(toHex(30, 30, 46)).toBe('#1e1e2e')
    expect(toHex(...hexToRgb('#ABCDEF'))).toBe('#abcdef')
  })

  it('refuse what is not a colour', () => {
    expect(() => hexToRgb('#abc')).toThrow(/not a #rrggbb colour/)
    expect(() => hexToRgb('1e1e2e')).toThrow(/not a #rrggbb colour/)
    expect(() => toHex(256, 0, 0)).toThrow(/not a colour channel/)
    expect(() => toHex(0, -1, 0)).toThrow(/not a colour channel/)
    expect(() => toHex(0, 0, 1.5)).toThrow(/not a colour channel/)
  })
})
