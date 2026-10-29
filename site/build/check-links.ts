// Run after `pnpm build`, with the documentation copied to `dist/client/docs`: every internal link and every sitemap address must lead to a file in the output that GitHub Pages serves without a redirect, the files a static host needs must be there, and no page or stylesheet of the site may load anything from another site. The pages of the documentation are built and checked by VitePress and are not read here.
import { resolve } from 'node:path'
import { listFiles } from './files.ts'
import { checkLinks, isMounted, MOUNTS, requiredFiles } from './links.ts'
import { readSiteConfig } from './site-config.ts'

const MAX_REPORTED = 50

const site = readSiteConfig(process.env)
const outDir = resolve(import.meta.dirname, '..', 'dist', 'client')
const files = await listFiles(outDir)

const missing = requiredFiles(site.domain).filter((file) => !files.includes(file))
const { problems, cssSources } = await checkLinks(outDir, files, site.base, site.origin, MOUNTS)

for (const file of missing) {
  const hint = isMounted(file, MOUNTS)
    ? ' (built by another tool: see Publishing in the README)'
    : ''
  console.error(`missing output file: ${file}${hint}`)
}
if (cssSources === 0)
  console.error('no stylesheet was scanned: the CSS is no longer where this check looks for it')
for (const problem of problems.slice(0, MAX_REPORTED)) {
  console.error(`${problem.page}: ${problem.reference} (${problem.reason})`)
}
if (problems.length > MAX_REPORTED) console.error(`... and ${problems.length - MAX_REPORTED} more`)

if (missing.length + problems.length > 0 || cssSources === 0) {
  process.exitCode = 1
} else {
  const pages = files.filter((file) => file.endsWith('.html') && !isMounted(file, MOUNTS)).length
  console.log(
    `check-links: ${pages} pages, every internal link and sitemap address is served without a redirect, nothing is loaded from another site (${cssSources} CSS sources scanned)`,
  )
}
