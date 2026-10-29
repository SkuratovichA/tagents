import { runsOf } from '../lib/pixels'

interface PixelArtProps {
  /** Rows of text: "#" is a filled pixel and any other character is empty. */
  rows: readonly string[]
  className?: string
}

/** Draws pixel art as SVG rectangles in the current text colour, one rectangle per run of pixels. */
export function PixelArt({ rows, className }: PixelArtProps) {
  const width = Math.max(...rows.map((row) => row.length))
  return (
    <svg
      className={className}
      viewBox={`0 0 ${width} ${rows.length}`}
      fill="currentColor"
      shapeRendering="crispEdges"
      aria-hidden="true"
      focusable="false"
    >
      {runsOf(rows, '#').map(({ x, y, length }) => (
        <rect key={`${x}-${y}`} x={x} y={y} width={length} height={1} />
      ))}
    </svg>
  )
}
