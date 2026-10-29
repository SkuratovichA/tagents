import { runsOf } from '../lib/pixels'
import './Mascot.css'
import { PIKACHU_COLORS, PIKACHU_ROWS } from './pikachu'

/** Who the mascot is, and the notice its footer owes. The rest of the site does not name it. */
export const MASCOT = {
  name: 'Pikachu',
  credit:
    'The mascot is a fan tribute and the site is not affiliated with Nintendo, Creatures Inc. or GAME FREAK inc. Pikachu is a trademark of Nintendo, Creatures Inc. and GAME FREAK inc.',
} as const

const WIDTH = Math.max(...PIKACHU_ROWS.map((row) => row.length))

/** The mascot on a plate. It hops when the pointer is on it and an alert shows over it; both are CSS, and with reduced motion only the alert is left. */
export function Mascot() {
  return (
    <div className="mascot" aria-hidden="true">
      <span className="mascot__alert">!</span>
      <svg
        className="mascot__sprite"
        viewBox={`0 0 ${WIDTH} ${PIKACHU_ROWS.length}`}
        shapeRendering="crispEdges"
        focusable="false"
      >
        {Object.entries(PIKACHU_COLORS).flatMap(([letter, fill]) =>
          runsOf(PIKACHU_ROWS, letter).map(({ x, y, length }) => (
            <rect key={`${letter}${x}-${y}`} x={x} y={y} width={length} height={1} fill={fill} />
          )),
        )}
      </svg>
    </div>
  )
}
