// Runs after `vite build`: writes the files a static host needs next to the prerendered page.
import { writeFile } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { listFiles } from './files.ts'
import { absoluteUrl, buildRobots, buildSitemap, sitemapUrls } from './outputs.ts'
import { readSiteConfig } from './site-config.ts'

const site = readSiteConfig(process.env)
const outDir = resolve(import.meta.dirname, '..', 'dist', 'client')

const urls = sitemapUrls(await listFiles(outDir), site)
const sitemapUrl = absoluteUrl(site, 'sitemap.xml')
if (sitemapUrl !== null) await writeFile(join(outDir, 'sitemap.xml'), buildSitemap(urls))
await writeFile(join(outDir, 'robots.txt'), buildRobots(sitemapUrl))
// Stops GitHub Pages from running Jekyll over the output.
await writeFile(join(outDir, '.nojekyll'), '')
if (site.domain !== null) await writeFile(join(outDir, 'CNAME'), `${site.domain}\n`)

console.log(
  `postbuild: robots.txt, .nojekyll` +
    (sitemapUrl === null ? '' : `, sitemap.xml with ${urls.length} page`) +
    (site.domain === null ? '' : `, CNAME ${site.domain}`),
)
