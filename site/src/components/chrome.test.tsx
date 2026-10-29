import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { fireEvent, render, screen, within } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { DEMO_COPY } from '../content'
import { DEMOS } from '../demos'
import { DOCS_URL, GITHUB_URL, LICENCE_URL } from '../lib/site'
import { MASCOT } from '../mascot'
import { Demo } from './Demo'
import { Footer } from './Footer'
import { Header } from './Header'

const read = (path: string) => readFileSync(resolve(import.meta.dirname, '..', path), 'utf8')

describe('the footer', () => {
  it('carries the credit of the mascot and the way to GitHub, the docs and the licence', () => {
    render(<Footer />)
    expect(screen.getByText(MASCOT.credit)).toBeInTheDocument()
    const links = within(screen.getByRole('navigation', { name: 'Elsewhere' }))
    expect(links.getByRole('link', { name: 'GitHub' })).toHaveAttribute('href', GITHUB_URL)
    expect(links.getByRole('link', { name: 'Docs' })).toHaveAttribute('href', DOCS_URL)
    expect(links.getByRole('link', { name: 'MIT licence' })).toHaveAttribute('href', LICENCE_URL)
  })

  it('links the licence file of the repository', () => {
    expect(LICENCE_URL).toBe(`${GITHUB_URL}/blob/main/LICENSE`)
  })
})

describe('the header', () => {
  it('names the page, its sections and the repository', () => {
    render(<Header />)
    const nav = within(screen.getByRole('navigation', { name: 'Page' }))
    expect(nav.getByRole('link', { name: 'Demo' })).toHaveAttribute(
      'href',
      expect.stringMatching(/#demo$/),
    )
    expect(nav.getByRole('link', { name: 'Install' })).toHaveAttribute(
      'href',
      expect.stringMatching(/#install$/),
    )
    expect(nav.getByRole('link', { name: 'GitHub' })).toHaveAttribute('href', GITHUB_URL)
  })

  it('has a theme button that says which theme is on', () => {
    render(<Header />)
    const toggle = screen.getByRole('button', { name: 'Dark theme' })
    expect(toggle).toHaveAttribute('aria-pressed', 'false')
    fireEvent.click(toggle)
    expect(toggle).toHaveAttribute('aria-pressed', 'true')
    fireEvent.click(toggle)
    expect(toggle).toHaveAttribute('aria-pressed', 'false')
  })
})

describe('the buttons of the recordings', () => {
  it('each have a name of their own', () => {
    render(
      <>
        {DEMO_COPY.map(({ scene, title, caption }) => {
          const recorded = DEMOS.find(({ id }) => id === scene)
          return recorded && <Demo key={scene} scene={recorded} title={title} caption={caption} />
        })}
      </>,
    )
    const names = screen.getAllByRole('button').map((button) => button.getAttribute('aria-label'))
    expect(names).toHaveLength(DEMO_COPY.length)
    expect(new Set(names).size).toBe(names.length)
    for (const [index, { title }] of DEMO_COPY.entries())
      expect(names[index]).toMatch(new RegExp(`^(Play|Replay): ${title}$`))
  })
})

describe('the stylesheets', () => {
  it.each(['styles.css', 'mascot/Mascot.css'])(
    'stop every animation and transition for a visitor who asked for less motion: %s',
    (file) => {
      const css = read(file)
      const start = css.indexOf('@media (prefers-reduced-motion: reduce)')
      expect(start).toBeGreaterThanOrEqual(0)
      const quiet = css.slice(start)
      expect(quiet).toMatch(/animation:\s*none/)
      expect(quiet).toMatch(/transition:\s*none/)
    },
  )
})
