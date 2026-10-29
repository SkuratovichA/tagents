import { memo, useMemo } from 'react'
import { RECORDED_WITH } from '../content'
import { screenAt, styleSheet } from '../lib/screen'
import type { Row, Scene } from '../lib/screen'
import { useDemo } from '../lib/useDemo'

interface DemoProps {
  scene: Scene
  title: string
  /** What the recording shows. It is the text for anyone who cannot see the screen. */
  caption: string
}

const ScreenRow = memo(function ScreenRow({ row }: { row: Row }) {
  return (
    <div className="screen__row">
      {row.map(([text, style], index) => (
        <span key={index} className={style === 0 ? undefined : `s${style}`}>
          {text}
        </span>
      ))}
    </div>
  )
})

/** A recording of the dashboard in a terminal on a wooden stand. The page is complete without scripts: it holds the last frame, and scripts play the recording once it is in view. */
export function Demo({ scene, title, caption }: DemoProps) {
  const { frame, stills, play, watch } = useDemo(scene)
  const rows = useMemo(() => screenAt(scene, frame), [scene, frame])
  const action = stills ? 'Play' : 'Replay'
  const scope = `.demo-${scene.id}`
  const sheet = useMemo(
    () => `${scope}{--cols:${scene.cols}}${styleSheet(scope, scene.styles)}`,
    [scene, scope],
  )
  return (
    <figure className={`example demo-${scene.id}`} ref={watch}>
      <style>{sheet}</style>
      <div className="stand">
        <div className="terminal">
          <div className="terminal__bar">
            <span className="terminal__dot" aria-hidden="true" />
            <span className="terminal__dot" aria-hidden="true" />
            <span className="terminal__dot" aria-hidden="true" />
            <span className="terminal__title">{title}</span>
            <button
              type="button"
              className="terminal__play"
              aria-label={`${action}: ${title}`}
              onClick={play}
            >
              {action}
            </button>
          </div>
          <div
            className="terminal__scroll"
            role="region"
            aria-label={`${title}: a terminal recording`}
            tabIndex={0}
          >
            <div className="screen" aria-hidden="true">
              {rows.map((row, index) => (
                <ScreenRow key={index} row={row} />
              ))}
            </div>
          </div>
        </div>
      </div>
      <figcaption>
        {caption} <span className="example__note">{RECORDED_WITH}</span>
      </figcaption>
    </figure>
  )
}
