import { useCallback, useEffect, useRef, useState } from 'react'
import { REDUCED_MOTION } from './motion'
import type { Scene } from './screen'

/** How much of a demo has to be on screen before it plays. */
const VISIBLE_SHARE = 0.5

export interface DemoPlayer {
  /** The frame on screen. Until the page has loaded it is the last one, which is what a page without scripts shows. */
  readonly frame: number
  /** Whether the visitor asked the system for less motion: the demo then waits to be played. */
  readonly stills: boolean
  /** Rewinds to the first frame and plays to the last. */
  readonly play: () => void
  /** Hand this to the element that holds the demo: the demo plays once when it comes into view. */
  readonly watch: (element: HTMLElement | null) => void
}

/** Plays a recorded scene on a timer, frame by frame, at the pace it was recorded at. */
export function useDemo(scene: Scene): DemoPlayer {
  const last = scene.frames.length - 1
  const [frame, setFrame] = useState(last)
  const [stills, setStills] = useState(false)
  const timer = useRef<number>(undefined)
  const element = useRef<HTMLElement | null>(null)
  const observer = useRef<IntersectionObserver | null>(null)

  const play = useCallback(() => {
    // Whoever plays first, the visitor or the observer, the other must not start it again.
    observer.current?.disconnect()
    observer.current = null
    window.clearTimeout(timer.current)
    setFrame(0)
    const started = performance.now()
    const step = (next: number) => {
      const due = scene.frames[next]?.t
      if (due === undefined) return
      timer.current = window.setTimeout(
        () => {
          setFrame(next)
          step(next + 1)
        },
        Math.max(0, due - (performance.now() - started)),
      )
    }
    step(1)
  }, [scene])

  useEffect(() => {
    const quiet = window.matchMedia(REDUCED_MOTION).matches
    setStills(quiet)
    if (!quiet) {
      // Scripts are running: take the recording back to its first frame and wait for it to be seen.
      setFrame(0)
      const target = element.current
      if (target === null || typeof IntersectionObserver === 'undefined') {
        play()
      } else {
        observer.current = new IntersectionObserver(
          ([entry]) => {
            if (entry?.isIntersecting === true) play()
          },
          { threshold: VISIBLE_SHARE },
        )
        observer.current.observe(target)
      }
    }
    return () => {
      observer.current?.disconnect()
      observer.current = null
      window.clearTimeout(timer.current)
    }
  }, [play])

  const watch = useCallback((node: HTMLElement | null) => {
    element.current = node
  }, [])

  return { frame, stills, play, watch }
}
