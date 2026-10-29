import { useEffect, useState } from 'react'
import { MOON, SUN } from '../lib/pixels'
import { applyTheme, currentTheme } from '../lib/theme'
import type { Theme } from '../lib/theme'
import { PixelArt } from './PixelArt'

/** Both icons are in the markup and the stylesheet shows the one for the theme on screen. Without scripts the button would do nothing, so the stylesheet shows it only when they run. */
export function ThemeToggle() {
  // The server cannot know the visitor's theme; the page reads it once it runs.
  const [theme, setTheme] = useState<Theme>('light')
  useEffect(() => {
    setTheme(currentTheme())
  }, [])
  return (
    <button
      type="button"
      className="theme-toggle"
      aria-label="Dark theme"
      aria-pressed={theme === 'dark'}
      onClick={() => {
        const next = currentTheme() === 'dark' ? 'light' : 'dark'
        applyTheme(next)
        setTheme(next)
      }}
    >
      <PixelArt rows={SUN} className="theme-toggle__icon theme-toggle__icon--sun" />
      <PixelArt rows={MOON} className="theme-toggle__icon theme-toggle__icon--moon" />
    </button>
  )
}
