import { readFile } from 'node:fs/promises'
import { join } from 'node:path'

export interface LinkProblem {
  page: string
  reference: string
  reason: string
}

export type Resolution =
  | { kind: 'external' }
  | { kind: 'broken'; reason: string }
  | { kind: 'internal'; file: string; fragment: string }

const REFERENCE = /\s(?:href|src)=(?:"([^"]*)"|'([^']*)')/g
const LOCATION = /<loc>([^<]*)<\/loc>/g
const TAG = /<([a-zA-Z][\w:-]*)((?:"[^"]*"|'[^']*'|[^'">])*)>/g
const ATTRIBUTE = /\s([^\s=>/]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/g
const STYLE_ELEMENT = /<style[^>]*>([\s\S]*?)<\/style>/gi
const CSS_URL = /url\(\s*(?:"([^"]*)"|'([^']*)'|([^)\s]*))\s*\)/gi
const CSS_IMPORT = /@import\s+(?:"([^"]*)"|'([^']*)')/gi
const REMOTE = /^\s*(?:https?:)?\/\//i
const REMOTE_IN_LIST = /(?:^|,)\s*(?:https?:)?\/\//i
const PLACEHOLDER_ORIGIN = 'https://site.invalid'

function decodeEntities(value: string): string {
  return value
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#x27;', "'")
    .replaceAll('&amp;', '&')
}

function safeDecode(value: string): string {
  try {
    return decodeURIComponent(value)
  } catch {
    return value
  }
}

/** The values of every href and src attribute in an HTML document. */
export function extractReferences(html: string): string[] {
  return Array.from(html.matchAll(REFERENCE), (match) => decodeEntities(match[1] ?? match[2] ?? ''))
}

/** The addresses a stylesheet loads: every `url(...)` and `@import`, when it names another site. */
export function findRemoteCss(css: string): string[] {
  const found = [
    ...Array.from(css.matchAll(CSS_URL), (match) => match[1] ?? match[2] ?? match[3] ?? ''),
    ...Array.from(css.matchAll(CSS_IMPORT), (match) => match[1] ?? match[2] ?? ''),
  ]
  return found.filter((address) => REMOTE.test(address))
}

/** The values of the attributes of a tag, by lower-case name. */
function attributesOf(source: string): Map<string, string> {
  return new Map(
    Array.from(source.matchAll(ATTRIBUTE), (match) => [
      (match[1] ?? '').toLowerCase(),
      decodeEntities(match[2] ?? match[3] ?? match[4] ?? ''),
    ]),
  )
}

/**
 * Everything in an HTML document that would make a browser fetch from another site: a tag other than an anchor with an address in an attribute, and every `url(...)` and `@import` of a `<style>` element or a `style` attribute. Outbound anchors, the canonical link and the `og:url` and `og:image` of the site itself (`origin`) are what a page may name; namespace declarations (`xmlns`) name nothing to load.
 */
export function findRemoteLoads(html: string, origin: string | null): string[] {
  const found: string[] = []
  for (const [, name = '', source = ''] of html.matchAll(TAG)) {
    const tag = name.toLowerCase()
    if (tag === 'a') continue
    const attributes = attributesOf(` ${source}`)
    if (tag === 'link' && attributes.get('rel') === 'canonical') continue
    for (const [attribute, value] of attributes) {
      if (attribute === 'xmlns' || attribute.startsWith('xmlns:')) continue
      if (attribute === 'style') found.push(...findRemoteCss(value))
      else if (attribute === 'srcset' ? REMOTE_IN_LIST.test(value) : REMOTE.test(value)) {
        const key = attributes.get('property') ?? attributes.get('name')
        const own = origin !== null && value.startsWith(`${origin}/`)
        if (tag === 'meta' && own && (key === 'og:url' || key === 'og:image')) continue
        found.push(value)
      }
    }
  }
  for (const [, css = ''] of html.matchAll(STYLE_ELEMENT)) found.push(...findRemoteCss(css))
  return found
}

/** The path of every address a sitemap lists. */
export function extractSitemapPaths(xml: string): string[] {
  return Array.from(xml.matchAll(LOCATION), (match) => {
    const location = decodeEntities(match[1] ?? '').trim()
    try {
      return new URL(location).pathname
    } catch {
      return location
    }
  })
}

/** The address a built file is served at, base included: "docs/a/index.html" is "/base/docs/a/". */
export function servedPath(file: string, base: string): string {
  if (file === 'index.html') return base
  if (file.endsWith('/index.html')) return `${base}${file.slice(0, -'index.html'.length)}`
  return `${base}${file}`
}

/** Finds the built file a reference found on `page` leads to. GitHub Pages serves a directory's index.html at the address that ends in a slash and answers the address without one with a redirect, so a link to the bare address of a page does not resolve. */
export function resolveReference(
  reference: string,
  page: string,
  base: string,
  files: ReadonlySet<string>,
): Resolution {
  let url: URL
  try {
    url = new URL(reference, `${PLACEHOLDER_ORIGIN}${servedPath(page, base)}`)
  } catch {
    return { kind: 'broken', reason: 'not a valid URL' }
  }
  if (url.origin !== PLACEHOLDER_ORIGIN) return { kind: 'external' }

  const pathname = safeDecode(url.pathname)
  if (!pathname.startsWith(base)) return { kind: 'broken', reason: `outside the base path ${base}` }

  const relative = pathname.slice(base.length)
  const isDirectory = relative === '' || relative.endsWith('/')
  const file = isDirectory ? `${relative}index.html` : relative
  if (files.has(file)) return { kind: 'internal', file, fragment: safeDecode(url.hash.slice(1)) }
  if (!isDirectory && files.has(`${relative}/index.html`)) {
    return { kind: 'broken', reason: `GitHub Pages redirects ${pathname} to ${pathname}/` }
  }
  return { kind: 'broken', reason: `no file for ${pathname}` }
}

export function hasAnchor(html: string, fragment: string): boolean {
  const escaped = fragment.replaceAll(/[.*+?^${}()|[\]\\]/g, '\\$&')
  return new RegExp(`\\s(?:id|name)=(?:"${escaped}"|'${escaped}')`).test(html)
}

/** Checks every internal href and src of every HTML file in `outDir`, the sitemap addresses, and that no page or stylesheet loads anything from another site. */
export async function checkLinks(
  outDir: string,
  files: readonly string[],
  base: string,
  origin: string | null = null,
): Promise<LinkProblem[]> {
  const known = new Set(files)
  const sources = new Map<string, string>()
  const source = async (file: string): Promise<string> => {
    const cached = sources.get(file)
    if (cached !== undefined) return cached
    const html = await readFile(join(outDir, file), 'utf8')
    sources.set(file, html)
    return html
  }

  const problems: LinkProblem[] = []
  for (const page of files.filter((file) => file.endsWith('.html'))) {
    for (const reference of new Set(findRemoteLoads(await source(page), origin))) {
      problems.push({ page, reference, reason: 'loads from another site' })
    }
    for (const reference of new Set(extractReferences(await source(page)))) {
      const target = resolveReference(reference, page, base, known)
      if (target.kind === 'broken') {
        problems.push({ page, reference, reason: target.reason })
        continue
      }
      const { fragment } = target.kind === 'internal' ? target : { fragment: '' }
      if (target.kind === 'internal' && fragment !== '' && fragment !== 'top') {
        if (target.file.endsWith('.html') && !hasAnchor(await source(target.file), fragment)) {
          problems.push({
            page,
            reference,
            reason: `no element with id "${fragment}" in ${target.file}`,
          })
        }
      }
    }
  }

  for (const file of files.filter((name) => name.endsWith('.css'))) {
    for (const reference of new Set(findRemoteCss(await source(file)))) {
      problems.push({ page: file, reference, reason: 'loads from another site' })
    }
  }

  if (known.has('sitemap.xml')) {
    for (const reference of extractSitemapPaths(await source('sitemap.xml'))) {
      const target = resolveReference(reference, 'index.html', base, known)
      if (target.kind === 'broken') {
        problems.push({ page: 'sitemap.xml', reference, reason: target.reason })
      }
    }
  }
  return problems
}
