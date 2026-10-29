import { act, fireEvent, render, screen } from '@testing-library/react'
import { renderToString } from 'react-dom/server'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { DEMO_COPY, INSTALL } from '../content'
import { DEMOS } from '../demos'
import { REDUCED_MOTION } from '../lib/motion'
import { screenAt } from '../lib/screen'
import type { Row } from '../lib/screen'
import { Demo } from './Demo'
import { Home } from './Home'

const textOf = (row: Row) => row.map(([text]) => text).join('')
const hero = DEMOS.find(({ id }) => id === 'hero')
if (hero === undefined) throw new Error('the hero recording is missing')
const firstCopy = DEMO_COPY[0]
if (firstCopy === undefined) throw new Error('the hero copy is missing')

function screensOf(root: ParentNode): string[][] {
  return Array.from(root.querySelectorAll('.screen'), (screenEl) =>
    Array.from(screenEl.querySelectorAll('.screen__row'), (row) => row.textContent),
  )
}

describe('the page as the server sends it, before any script has run', () => {
  const page = document.createElement('div')
  page.innerHTML = renderToString(<Home />)

  it('holds every recording on its last frame', () => {
    expect(screensOf(page)).toEqual(
      DEMO_COPY.map(({ scene }) => {
        const scene_ = DEMOS.find(({ id }) => id === scene)
        return scene_ ? screenAt(scene_).map(textOf) : []
      }),
    )
  })

  it('has the install command and the way to the repository in plain text and links', () => {
    expect(page.textContent).toContain(INSTALL.command)
    expect(page.querySelector('a[href="https://github.com/SkuratovichA/tagents"]')).not.toBeNull()
    expect(page.querySelector('a[href="#install"]')).not.toBeNull()
  })

  it('has one h1 and a heading for every section', () => {
    expect(page.querySelectorAll('h1')).toHaveLength(1)
    expect(Array.from(page.querySelectorAll('h2'), (heading) => heading.textContent)).toEqual([
      'See it work',
      'What it does',
      'A closer look',
      'Never lose a session',
      'Install',
      'Notifications, status bar, plugin',
    ])
  })

  it('loads nothing from another site', () => {
    const loaded = Array.from(
      page.querySelectorAll('[src], link[href], [srcset]'),
      (el) => el.getAttribute('src') ?? el.getAttribute('href') ?? '',
    )
    expect(loaded.filter((url) => /^(https?:)?\/\//.test(url))).toEqual([])
    expect(page.innerHTML).not.toMatch(/url\(\s*['"]?https?:/)
  })

  it('gives every recording a name and its caption as text', () => {
    for (const { title, caption } of DEMO_COPY) {
      expect(page.querySelector(`[aria-label="${title}: a terminal recording"]`)).not.toBeNull()
      expect(page.textContent).toContain(caption)
    }
  })
})

describe('a recording in the browser', () => {
  const reduced = (matches: boolean) =>
    vi.stubGlobal('matchMedia', (query: string) => ({
      matches: matches && query === REDUCED_MOTION,
      media: query,
      addEventListener: () => undefined,
      removeEventListener: () => undefined,
    }))
  const lastTime = hero.frames.at(-1)?.t ?? 0
  const onScreen = () => screensOf(document.body)[0] ?? []
  const firstFrame = screenAt(hero, 0).map(textOf)
  const lastFrame = screenAt(hero).map(textOf)

  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
    vi.unstubAllGlobals()
  })

  it('goes back to its first frame and plays to its last', () => {
    reduced(false)
    render(<Demo scene={hero} title={firstCopy.title} caption={firstCopy.caption} />)
    expect(onScreen()).toEqual(firstFrame)
    act(() => {
      vi.advanceTimersByTime(lastTime + 50)
    })
    expect(onScreen()).toEqual(lastFrame)
    expect(screen.getByRole('button', { name: 'Replay' })).toBeInTheDocument()
  })

  it('stays on its last frame for a visitor who asked for less motion, until asked to play', () => {
    reduced(true)
    render(<Demo scene={hero} title={firstCopy.title} caption={firstCopy.caption} />)
    act(() => {
      vi.advanceTimersByTime(lastTime + 50)
    })
    expect(onScreen()).toEqual(lastFrame)
    fireEvent.click(screen.getByRole('button', { name: 'Play' }))
    expect(onScreen()).toEqual(firstFrame)
    act(() => {
      vi.advanceTimersByTime(lastTime + 50)
    })
    expect(onScreen()).toEqual(lastFrame)
  })

  it('can be reached and scrolled with the keyboard', () => {
    reduced(false)
    render(<Demo scene={hero} title={firstCopy.title} caption={firstCopy.caption} />)
    expect(
      screen.getByRole('region', { name: `${firstCopy.title}: a terminal recording` }),
    ).toHaveAttribute('tabindex', '0')
  })
})
