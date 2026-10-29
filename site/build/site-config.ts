export interface SiteConfig {
  /** The path the site is served under: "/" or "/name/", always with both slashes. */
  base: string
  /** The custom domain from SITE_DOMAIN, or null. */
  domain: string | null
  /** The scheme and host that absolute URLs (canonical, sitemap) are built on: the domain, or null while the site has none. */
  origin: string | null
}

const HOST_NAME = /^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$/

export function normaliseBase(raw: string | undefined): string {
  const value = (raw ?? '').trim()
  if (value === '' || value === '/') return '/'
  const trimmed = value.replace(/^\/+|\/+$/g, '')
  if (/[\s?#]|\.\.|\/\//.test(trimmed)) {
    throw new Error(`SITE_BASE must be a plain path such as /tagents-site/, got "${value}"`)
  }
  return `/${trimmed}/`
}

export function readSiteConfig(env: Readonly<Record<string, string | undefined>>): SiteConfig {
  const base = normaliseBase(env.SITE_BASE)
  const domain = (env.SITE_DOMAIN ?? '').trim().toLowerCase()
  if (domain === '') return { base, domain: null, origin: null }
  if (!HOST_NAME.test(domain)) {
    throw new Error(`SITE_DOMAIN must be a host name such as tagents.example.org, got "${domain}"`)
  }
  return { base, domain, origin: `https://${domain}` }
}
