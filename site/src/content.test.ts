import { existsSync, readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  DEMO_COPY,
  DESCRIPTION,
  EXTRAS,
  FEATURES,
  INSTALL,
  LEAD,
  PITCH,
  RECORDED_WITH,
  RESURRECT,
  SETTINGS_JSON,
  TITLE,
} from './content'

const readme = resolve(import.meta.dirname, '../../README.md')

// The site is meant to be cut out of the repository; without the README next to it there is nothing to compare with.
describe.skipIf(!existsSync(readme))('the commands on the page', () => {
  const text = existsSync(readme) ? readFileSync(readme, 'utf8') : ''

  it.each([
    ['the install command', INSTALL.command],
    ['the settings.json', SETTINGS_JSON],
    ['the tmux-resurrect lines', RESURRECT.tmuxConf],
    ['the notification commands', EXTRAS.notifications.commands],
    ['the status bar line', EXTRAS.statusBar.command],
    ['the plugin command', EXTRAS.plugin.command],
    ['the start command', INSTALL.start],
  ])('are the README’s: %s', (_what, commands) => {
    for (const line of commands.split('\n')) expect(text).toContain(line)
  })

  it('has the settings.json as one block, character for character', () => {
    expect(text).toContain(SETTINGS_JSON)
  })
})

describe('the words on the page', () => {
  const everything = [
    TITLE,
    DESCRIPTION,
    PITCH,
    LEAD,
    RECORDED_WITH,
    ...FEATURES.flatMap(({ title, text }) => [title, text]),
    ...DEMO_COPY.flatMap(({ title, caption }) => [title, caption]),
    RESURRECT.title,
    RESURRECT.text,
    RESURRECT.without,
    INSTALL.intro,
    INSTALL.where,
    INSTALL.hooksNote,
    INSTALL.startIntro,
    EXTRAS.notifications.text,
    EXTRAS.statusBar.text,
    EXTRAS.plugin.text,
  ].join('\n')

  it('make no claim about speed, memory or resource use, and compare with nothing', () => {
    expect(everything).not.toMatch(
      /\b(fast|faster|fastest|instant|instantly|lightweight|light|tiny|small|memory|ram|cpu|latency|overhead|benchmark|daemon)\b/i,
    )
    expect(everything).not.toMatch(/\b(better than|unlike|alternative|vs\.?|versus|compared)\b/i)
    expect(everything).not.toMatch(/\d+\s?(ms|MB|KB|GB|%)/)
  })

  it('give no licence, which the repository does not have', () => {
    expect(everything).not.toMatch(/licen[cs]e|open[ -]source|\bMIT\b/i)
  })

  it('have seven features, the number the layout is balanced for', () => {
    expect(FEATURES).toHaveLength(7)
  })
})
