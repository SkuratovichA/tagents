import tailwindcss from '@tailwindcss/vite'
import { tanstackStart } from '@tanstack/react-start/plugin/vite'
import viteReact from '@vitejs/plugin-react'
import { defineConfig } from 'vite'
import { prerenderOptions } from './build/prerender.ts'
import { readSiteConfig } from './build/site-config.ts'

const site = readSiteConfig(process.env)

export default defineConfig({
  // SITE_BASE is the one source of the base path: Vite prefixes asset URLs with it and TanStack Start derives the router's basepath from it.
  base: site.base,
  // The address the site is served at, or null while it has none: only then can a page name itself.
  define: { __SITE_ORIGIN__: JSON.stringify(site.origin) },
  server: { port: 3000 },
  plugins: [
    tailwindcss(),
    tanstackStart({
      // sitemap.xml is written by build/postbuild.ts, from the pages that were prerendered.
      sitemap: { enabled: false },
      prerender: prerenderOptions(site.base),
      // GitHub Pages serves 404.html for every unknown address.
      pages: [{ path: '/404', prerender: { outputPath: '/404.html' } }],
    }),
    // The React plugin has to come after Start's.
    viteReact(),
  ],
})
