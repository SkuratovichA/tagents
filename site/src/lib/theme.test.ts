import { afterEach, describe, expect, it, vi } from 'vitest'
import { THEME_STORAGE_KEY, applyTheme, currentTheme, themeInitScript } from './theme'

afterEach(() => {
  localStorage.clear()
  document.documentElement.classList.remove('js')
})

function runInitScript() {
  const script = document.createElement('script')
  script.textContent = themeInitScript
  document.head.append(script)
}

describe('themeInitScript', () => {
  it('marks the page as one that runs scripts', () => {
    runInitScript()
    expect(document.documentElement).toHaveClass('js')
  })

  it('puts a stored choice on the page before the first paint', () => {
    localStorage.setItem(THEME_STORAGE_KEY, 'dark')
    runInitScript()
    expect(document.documentElement.dataset.theme).toBe('dark')
  })

  it('ignores a stored value that is not a theme', () => {
    localStorage.setItem(THEME_STORAGE_KEY, 'sepia')
    runInitScript()
    expect(document.documentElement.dataset.theme).toBeUndefined()
  })
})

describe('applyTheme', () => {
  it('shows the theme and remembers it', () => {
    applyTheme('dark')
    expect(currentTheme()).toBe('dark')
    expect(localStorage.getItem(THEME_STORAGE_KEY)).toBe('dark')
  })

  it('still shows the theme when storage is blocked', () => {
    const blocked = vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => {
      throw new Error('blocked')
    })
    try {
      applyTheme('light')
    } finally {
      blocked.mockRestore()
    }
    expect(currentTheme()).toBe('light')
  })
})
