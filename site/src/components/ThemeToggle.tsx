import { MOON, SUN } from '../lib/pixels'
import { applyTheme, currentTheme } from '../lib/theme'
import { PixelArt } from './PixelArt'

/** Both icons are in the markup and the stylesheet shows the one for the theme on screen. Without scripts the button would do nothing, so the stylesheet shows it only when they run. */
export function ThemeToggle() {
  return (
    <button
      type="button"
      className="theme-toggle"
      aria-label="Switch between the light and the dark theme"
      onClick={() => {
        applyTheme(currentTheme() === 'dark' ? 'light' : 'dark')
      }}
    >
      <PixelArt rows={SUN} className="theme-toggle__icon theme-toggle__icon--sun" />
      <PixelArt rows={MOON} className="theme-toggle__icon theme-toggle__icon--moon" />
    </button>
  )
}
