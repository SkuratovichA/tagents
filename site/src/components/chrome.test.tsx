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
  it('carries the credit of the mascot and the way to GitHub, the docs and the licence, in that order', () => {
    render(<Footer />)
    expect(screen.getByText(MASCOT.credit)).toBeInTheDocument()
    const links = within(screen.getByRole('contentinfo')).getAllByRole('link')
    expect(links.map((link) => [link.textContent, link.getAttribute('href')])).toEqual([
      ['GitHub', GITHUB_URL],
      ['Docs', DOCS_URL],
      ['MIT licence', LICENCE_URL],
    ])
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
    for (const [index, { title }] of DEMO_COPY.entries()) {
      const name = names[index]
      expect([`Play: ${title}`, `Replay: ${title}`]).toContain(name)
    }
  })
})

/** The text between the braces of the block that starts with `header`, found by matching its braces. */
function blockOf(css: string, header: string): string {
  const start = css.indexOf(header)
  if (start < 0) throw new Error(`no block starts with ${header}`)
  const open = css.indexOf('{', start)
  let depth = 0
  for (let at = open; at < css.length; at++) {
    if (css[at] === '{') depth++
    else if (css[at] === '}' && --depth === 0) return css.slice(open + 1, at)
  }
  throw new Error(`the block of ${header} is not closed`)
}

/** The declarations of the rule in `block` whose selector is exactly `selector` (white space collapsed). */
function declarationsOf(block: string, selector: string): string {
  for (const [, selectors = '', body = ''] of block.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    if (selectors.trim().replaceAll(/\s+/g, ' ') === selector) return body
  }
  throw new Error(`no rule for ${selector}`)
}

describe('the stylesheets', () => {
  const quiet = (file: string) => blockOf(read(file), '@media (prefers-reduced-motion: reduce)')

  it('stop every animation and transition on the page for a visitor who asked for less motion', () => {
    const body = declarationsOf(quiet('styles.css'), '*, *::before, *::after')
    expect(body).toMatch(/animation:\s*none/)
    expect(body).toMatch(/transition:\s*none/)
  })

  it('stop the animation and the transition of the mascot for the same visitor', () => {
    const block = quiet('mascot/Mascot.css')
    expect(declarationsOf(block, '.mascot:hover .mascot__sprite')).toMatch(/animation:\s*none/)
    expect(declarationsOf(block, '.mascot__alert')).toMatch(/transition:\s*none/)
  })
})
