// Run after `pnpm build`: every internal link and every sitemap address must lead to a file in the output that GitHub Pages serves without a redirect, the files a static host needs must be there, and no page or stylesheet may load anything from another site.
import { resolve } from 'node:path'
import { listFiles } from './files.ts'
import { checkLinks } from './links.ts'
import { readSiteConfig } from './site-config.ts'

const MAX_REPORTED = 50

const site = readSiteConfig(process.env)
const outDir = resolve(import.meta.dirname, '..', 'dist', 'client')
const files = await listFiles(outDir)

const required = ['index.html', '404.html', 'robots.txt', '.nojekyll']
if (site.domain !== null) required.push('CNAME', 'sitemap.xml')
const missing = required.filter((file) => !files.includes(file))
const { problems, cssSources } = await checkLinks(outDir, files, site.base, site.origin)

for (const file of missing) console.error(`missing output file: ${file}`)
if (cssSources === 0)
  console.error('no stylesheet was scanned: the CSS is no longer where this check looks for it')
for (const problem of problems.slice(0, MAX_REPORTED)) {
  console.error(`${problem.page}: ${problem.reference} (${problem.reason})`)
}
if (problems.length > MAX_REPORTED) console.error(`... and ${problems.length - MAX_REPORTED} more`)

if (missing.length + problems.length > 0 || cssSources === 0) {
  process.exitCode = 1
} else {
  const pages = files.filter((file) => file.endsWith('.html')).length
  console.log(
    `check-links: ${pages} pages, every internal link and sitemap address is served without a redirect, nothing is loaded from another site (${cssSources} CSS sources scanned)`,
  )
}
