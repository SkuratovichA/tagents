import { createRouter } from '@tanstack/react-router'
import type { RouterHistory } from '@tanstack/react-router'
import { routeTree } from './routeTree.gen'

interface SiteRouterOptions {
  /** Only tests pass a history: the app uses the browser's, or the request's on the server. */
  history?: RouterHistory
}

/** Start calls this once per request on the server and once in the browser. The base path comes from Vite's `base`. */
export function getRouter({ history }: SiteRouterOptions = {}) {
  return createRouter({
    routeTree,
    history,
    // GitHub Pages serves a directory's index.html at the address with a slash and redirects the one
    // without, so every link the router writes ends in a slash.
    trailingSlash: 'always',
    defaultPreload: 'intent',
    scrollRestoration: true,
  })
}

declare module '@tanstack/react-router' {
  interface Register {
    router: ReturnType<typeof getRouter>
  }
}
