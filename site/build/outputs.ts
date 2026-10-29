import type { SiteConfig } from './site-config.ts'

/** The address of a built HTML file inside the site, or null for pages that stay out of the sitemap. */
export function pagePath(file: string): string | null {
  const path =
    file === 'index.html'
      ? '/'
      : file.endsWith('/index.html')
        ? `/${file.slice(0, -'index.html'.length)}`
        : null
  return path === '/404/' ? null : path
}

/** The absolute address of `path` under the base, or null while the site has no domain to build it on. */
export function absoluteUrl(site: SiteConfig, path: string): string | null {
  if (site.origin === null) return null
  return new URL(`${site.base}${path.replace(/^\//, '')}`, site.origin).href
}

/** The sitemap addresses of the built pages, sorted. Empty while the site has no domain. */
export function sitemapUrls(files: readonly string[], site: SiteConfig): string[] {
  return files
    .flatMap((file) => {
      const path = pagePath(file)
      const url = path === null ? null : absoluteUrl(site, path)
      return url === null ? [] : [url]
    })
    .sort()
}

function escapeXml(value: string): string {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
}

export function buildSitemap(urls: readonly string[]): string {
  const entries = urls.map((url) => `  <url><loc>${escapeXml(url)}</loc></url>`).join('\n')
  return `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${entries}\n</urlset>\n`
}

/** robots.txt lets every crawler in, and points at the sitemap when there is one. */
export function buildRobots(sitemapUrl: string | null): string {
  return sitemapUrl === null
    ? 'User-agent: *\nAllow: /\n'
    : `User-agent: *\nAllow: /\n\nSitemap: ${sitemapUrl}\n`
}
