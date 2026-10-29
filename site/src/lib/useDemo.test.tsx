import { act, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { useDemo } from './useDemo'
import type { Scene } from './screen'

const scene: Scene = {
  id: 'probe',
  cols: 4,
  rows: 1,
  styles: [{}],
  frames: [
    { t: 0, rows: [[0, [['a', 0]]]] },
    { t: 100, rows: [[0, [['b', 0]]]] },
    { t: 200, rows: [[0, [['c', 0]]]] },
  ],
}

/** The observer jsdom lacks: it keeps its callback so a test can say when the figure is seen, and it says nothing once disconnected, as a real one does. */
class FakeObserver {
  static instances: FakeObserver[] = []
  disconnected = 0
  private readonly callback: (entries: { isIntersecting: boolean }[]) => void
  constructor(callback: (entries: { isIntersecting: boolean }[]) => void) {
    this.callback = callback
    FakeObserver.instances.push(this)
  }
  observe = () => undefined
  unobserve = () => undefined
  takeRecords = () => []
  disconnect = () => {
    this.disconnected += 1
  }
  see(isIntersecting: boolean) {
    if (this.disconnected === 0) this.callback([{ isIntersecting }])
  }
}

function Probe() {
  const { frame, play, watch } = useDemo(scene)
  return (
    <figure ref={watch}>
      <output>{frame}</output>
      <button type="button" onClick={play}>
        replay
      </button>
    </figure>
  )
}

const shown = () => screen.getByRole('status').textContent
const observer = () => {
  const [only] = FakeObserver.instances
  if (only === undefined) throw new Error('the page never asked to be told when the figure is seen')
  return only
}

beforeEach(() => {
  FakeObserver.instances = []
  vi.useFakeTimers()
  vi.stubGlobal('IntersectionObserver', FakeObserver)
})
afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

describe('a recording that waits to be seen', () => {
  it('plays nothing until half of it is on screen', () => {
    render(<Probe />)
    expect(shown()).toBe('0')
    act(() => {
      vi.advanceTimersByTime(1000)
    })
    expect(shown()).toBe('0')
    expect(vi.getTimerCount()).toBe(0)
    act(() => {
      observer().see(false)
    })
    act(() => {
      vi.advanceTimersByTime(1000)
    })
    expect(shown()).toBe('0')
    expect(observer().disconnected).toBe(0)
  })

  it('plays once when it is seen, stops watching, and does not start again', () => {
    render(<Probe />)
    act(() => {
      observer().see(true)
    })
    expect(observer().disconnected).toBe(1)
    act(() => {
      vi.advanceTimersByTime(250)
    })
    expect(shown()).toBe('2')
    act(() => {
      observer().see(true)
    })
    expect(shown()).toBe('2')
    expect(vi.getTimerCount()).toBe(0)
  })

  it('is not started again by the observer after the visitor pressed replay', () => {
    render(<Probe />)
    fireEvent.click(screen.getByRole('button', { name: 'replay' }))
    expect(observer().disconnected).toBe(1)
    act(() => {
      vi.advanceTimersByTime(250)
    })
    expect(shown()).toBe('2')
    act(() => {
      observer().see(true)
    })
    expect(shown()).toBe('2')
  })

  it('leaves no timer and no observer behind when the page is left mid-recording', () => {
    const { unmount } = render(<Probe />)
    act(() => {
      observer().see(true)
    })
    act(() => {
      vi.advanceTimersByTime(120)
    })
    expect(shown()).toBe('1')
    unmount()
    expect(vi.getTimerCount()).toBe(0)
  })

  it('stops watching when the page is left before the figure was seen', () => {
    const { unmount } = render(<Probe />)
    unmount()
    expect(observer().disconnected).toBe(1)
  })

  it('clears its timer on leaving when there is no observer to wait for', () => {
    vi.stubGlobal('IntersectionObserver', undefined)
    const { unmount } = render(<Probe />)
    expect(vi.getTimerCount()).toBe(1)
    unmount()
    expect(vi.getTimerCount()).toBe(0)
  })
})
