import { HeadContent, Outlet, Scripts, createRootRoute } from '@tanstack/react-router'
import type { ReactNode } from 'react'
import { Footer } from '../components/Footer'
import { Header } from '../components/Header'
import { asset } from '../lib/base'
import { themeInitScript } from '../lib/theme'
import appCss from '../styles.css?url'

export const Route = createRootRoute({
  head: () => ({
    meta: [
      { charSet: 'utf-8' },
      { name: 'viewport', content: 'width=device-width, initial-scale=1' },
    ],
    links: [
      { rel: 'icon', type: 'image/png', sizes: '64x64', href: asset('mascot/favicon-64.png') },
      { rel: 'apple-touch-icon', href: asset('mascot/apple-touch-icon.png') },
      // The demos are drawn in this font, and a fallback would move every column.
      {
        rel: 'preload',
        as: 'font',
        type: 'font/woff2',
        href: asset('fonts/dejavu-sans-mono-400.woff2'),
        crossOrigin: 'anonymous',
      },
      { rel: 'stylesheet', href: appCss },
    ],
  }),
  shellComponent: RootDocument,
  component: RootLayout,
})

function RootDocument({ children }: { children: ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        {/* Sets a stored theme before the first paint, so the page never flashes the other one. */}
        <script dangerouslySetInnerHTML={{ __html: themeInitScript }} />
        <HeadContent />
      </head>
      <body>
        {children}
        <Scripts />
      </body>
    </html>
  )
}

function RootLayout() {
  return (
    <>
      <a className="skip" href="#content">
        Skip to the content
      </a>
      <Header />
      <main id="content" tabIndex={-1}>
        <Outlet />
      </main>
      <Footer />
    </>
  )
}
