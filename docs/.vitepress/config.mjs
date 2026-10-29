// The VitePress config as a plain object: it imports nothing from `vitepress`, so the docs toolchain
// is never a dependency of this repository (`pnpm docs:build` runs it through `pnpm dlx`).
export default {
  title: 'tagents',
  description: 'A dashboard of every Claude Code session running under tmux: which one is blocked on you, what each is doing and what it costs.',
  lang: 'en-US',
  // The documentation is published under /docs/ of the site, next to the page at / (.github/workflows/site.yml).
  base: '/docs/',
  cleanUrls: true,
  lastUpdated: false,
  srcExclude: ['demo/**'],

  themeConfig: {
    nav: [
      { text: 'Guide', link: '/guide/getting-started', activeMatch: '/guide/' },
      { text: 'Architecture', link: '/architecture/overview', activeMatch: '/architecture/' },
      { text: 'Development', link: '/development' },
    ],

    sidebar: [
      {
        text: 'Guide',
        items: [
          { text: 'Getting started', link: '/guide/getting-started' },
          { text: 'The dashboard', link: '/guide/dashboard' },
          { text: 'States and order', link: '/guide/states' },
          { text: 'Keys', link: '/guide/keys' },
          { text: 'Notifications', link: '/guide/notifications' },
          { text: 'Resurrect', link: '/guide/resurrect' },
          { text: 'Closed sessions', link: '/guide/closed-sessions' },
          { text: 'Accounts and configuration', link: '/guide/accounts' },
          { text: 'Cost', link: '/guide/cost' },
          { text: 'Notes workspace', link: '/guide/notes' },
          { text: 'Claude Code plugin', link: '/guide/claude-code-plugin' },
        ],
      },
      {
        text: 'Architecture',
        items: [
          { text: 'Overview', link: '/architecture/overview' },
          { text: 'How the dashboard stays current', link: '/architecture/refresh' },
          { text: 'The generated contract', link: '/architecture/contract' },
        ],
      },
      {
        text: 'Development',
        items: [{ text: 'Working on tagents', link: '/development' }],
      },
    ],

    socialLinks: [{ icon: 'github', link: 'https://github.com/SkuratovichA/tagents' }],
    editLink: {
      pattern: 'https://github.com/SkuratovichA/tagents/edit/main/docs/:path',
      text: 'Edit this page on GitHub',
    },
    search: { provider: 'local' },
    outline: { level: [2, 3] },
  },
}
