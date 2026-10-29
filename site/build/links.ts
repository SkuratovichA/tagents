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

/**
 * Finds the built file a reference found on `page` leads to. GitHub Pages serves a directory's
 * index.html at the address that ends in a slash and answers the address without one with a
 * redirect, so a link to the bare address of a page does not resolve.
 */
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

/** Checks every internal href and src of every HTML file in `outDir`, and the sitemap addresses. */
export async function checkLinks(
  outDir: string,
  files: readonly string[],
  base: string,
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
