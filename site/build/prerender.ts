import { isMountedPath } from './links.ts'

/** The prerender options of the site. The router has no routes in a mounted directory, so a crawled link into one would prerender its not-found page where the other tool's pages belong. */
export function prerenderOptions(base: string): {
  enabled: true
  crawlLinks: true
  failOnError: true
  filter: (page: { path: string }) => boolean
} {
  return {
    enabled: true,
    crawlLinks: true,
    failOnError: true,
    filter: (page) => !isMountedPath(page.path, base),
  }
}
