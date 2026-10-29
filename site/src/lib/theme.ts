export type Theme = 'light' | 'dark'

export const THEME_STORAGE_KEY = 'tagents-theme'

/** Runs in the head before the first paint, so a stored choice never flashes the other theme. It also marks the page as one that runs scripts, which is what shows the controls that need them. */
export const themeInitScript = `document.documentElement.classList.add('js');try{var t=localStorage.getItem('${THEME_STORAGE_KEY}');if(t==='light'||t==='dark'){document.documentElement.dataset.theme=t}}catch(e){}`

/** The theme on screen: the explicit choice if there is one, else the system preference. */
export function currentTheme(): Theme {
  const choice = document.documentElement.dataset.theme
  if (choice === 'light' || choice === 'dark') return choice
  return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'
}

/** Shows a theme and remembers it. Storage can be blocked, then the choice lasts for the visit. */
export function applyTheme(theme: Theme): void {
  document.documentElement.dataset.theme = theme
  try {
    localStorage.setItem(THEME_STORAGE_KEY, theme)
  } catch {
    // Private windows and blocked site data throw here; the theme still applies for this visit.
  }
}
