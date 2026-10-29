import { existsSync, readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import * as content from './content'
import { EXTRAS, FEATURES, INSTALL, RESURRECT, SETTINGS_JSON } from './content'
import { MASCOT } from './mascot'

const readme = resolve(import.meta.dirname, '../../README.md')

/** The bodies of the README's fenced blocks, each padded with a line break on both sides so that a whole line can be looked for. */
function fencedBlocks(text: string): string[] {
  return Array.from(text.matchAll(/^```[^\n]*\n([\s\S]*?)^```/gm), (match) => `\n${match[1]}`)
}

// The site is meant to be cut out of the repository; without the README next to it there is nothing to compare with.
describe.skipIf(!existsSync(readme))('the commands on the page', () => {
  const text = existsSync(readme) ? readFileSync(readme, 'utf8') : ''
  const blocks = fencedBlocks(text)

  it.each([
    ['the install command', INSTALL.command],
    ['the settings.json', SETTINGS_JSON],
    ['the tmux-resurrect lines', RESURRECT.tmuxConf],
    ['the notification commands', EXTRAS.notifications.commands],
    ['the status bar line', EXTRAS.statusBar.command],
    ['the plugin command', EXTRAS.plugin.command],
    ['the start command', INSTALL.start],
  ])('are the README’s, as lines of one fenced block: %s', (_what, commands) => {
    expect(blocks.some((block) => block.includes(`\n${commands}\n`))).toBe(true)
  })

  it('has as many features as the README lists under "What it does"', () => {
    const section = /^## What it does\n([\s\S]*?)^(?:---|## )/m.exec(text)?.[1] ?? ''
    expect(section.match(/^- \*\*/gm)).toHaveLength(FEATURES.length)
  })
})

/** Every string a module exports, however deep, but not the commands: those are the README's, and the test above pins them to it. */
function stringsOf(value: unknown, skip: ReadonlySet<unknown>): string[] {
  if (typeof value === 'string') return skip.has(value) ? [] : [value]
  if (typeof value !== 'object' || value === null) return []
  return Object.values(value).flatMap((inner) => stringsOf(inner, skip))
}

describe('the words on the page', () => {
  const commands = new Set<unknown>([
    INSTALL.command,
    INSTALL.start,
    SETTINGS_JSON,
    RESURRECT.tmuxConf,
    EXTRAS.notifications.commands,
    EXTRAS.statusBar.command,
    EXTRAS.plugin.command,
  ])
  const everything = [...stringsOf(content, commands), MASCOT.credit].join('\n')

  it('are all of what content.ts exports and the footer says', () => {
    expect(everything.length).toBeGreaterThan(2000)
    expect(everything).toContain(FEATURES[0]?.text)
    expect(everything).toContain(EXTRAS.plugin.text)
    expect(everything).toContain(MASCOT.credit)
  })

  it('make no claim about speed, memory or resource use, and compare with nothing', () => {
    expect(everything).not.toMatch(
      /\b(fast|faster|fastest|instant|instantly|lightweight|light|tiny|small|memory|ram|cpu|latency|overhead|benchmark|daemon)\b/i,
    )
    expect(everything).not.toMatch(/\b(better than|unlike|alternative|vs\.?|versus|compared)\b/i)
    expect(everything).not.toMatch(/\d+\s?(ms|MB|KB|GB|%)/)
  })
})
