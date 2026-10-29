export type Rgb = readonly [number, number, number]

/** The channels of a `#rrggbb` colour. */
export function hexToRgb(hex: string): Rgb {
  const match = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(hex)
  if (match === null) throw new Error(`${hex} is not a #rrggbb colour`)
  const [, r = '', g = '', b = ''] = match
  return [Number.parseInt(r, 16), Number.parseInt(g, 16), Number.parseInt(b, 16)]
}

/** The `#rrggbb` colour of three channels, each an integer from 0 to 255. */
export function toHex(r: number, g: number, b: number): string {
  for (const channel of [r, g, b]) {
    if (!Number.isInteger(channel) || channel < 0 || channel > 255)
      throw new Error(`${channel} is not a colour channel from 0 to 255`)
  }
  return `#${[r, g, b].map((channel) => channel.toString(16).padStart(2, '0')).join('')}`
}
