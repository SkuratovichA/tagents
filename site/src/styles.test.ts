import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import { TERMINAL } from './lib/screen'

const css = readFileSync(resolve(import.meta.dirname, 'styles.css'), 'utf8')

function declarationsOf(block: RegExp): string[] {
  const body = block.exec(css)?.[1]
  if (body === undefined) throw new Error(`styles.css has no block matching ${block.source}`)
  return Array.from(body.matchAll(/[\w-]+:\s*[^;]+;/g), (match) => match[0])
}

describe('dark theme tokens', () => {
  it('are the same for the system preference and for an explicit choice', () => {
    const system = declarationsOf(
      /@media \(prefers-color-scheme: dark\) \{\s*:root:not\(\[data-theme=["']light["']\]\) \{([^}]*)\}/,
    )
    const chosen = declarationsOf(/:root\[data-theme=["']dark["']\] \{([^}]*)\}/)
    expect(system.length).toBeGreaterThan(8)
    expect(system).toEqual(chosen)
  })
})

describe('terminal colours', () => {
  it('are the ones the demos were recorded with', () => {
    const root = declarationsOf(/:root \{([^}]*)\}/)
    expect(root).toContain(`--term-bg: ${TERMINAL.bg};`)
    expect(root).toContain(`--term-fg: ${TERMINAL.fg};`)
  })
})
