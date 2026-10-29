import { DESCRIPTION } from '../content'
import { asset } from './base'

type Meta =
  { title: string } | { name: string; content: string } | { property: string; content: string }

interface Head {
  meta: Meta[]
  links: { rel: string; href: string }[]
}

/**
 * The head entries of a page: its title and description, and what a link preview shows. A page can only name its own address, and the image a preview shows, once the site has an address (SITE_DOMAIN at build time): until then those entries are left out, because a relative one would point nowhere.
 */
export function pageHead(
  title: string,
  description: string,
  origin: string | null = __SITE_ORIGIN__,
): Head {
  const meta: Meta[] = [
    { title },
    { name: 'description', content: description },
    { property: 'og:type', content: 'website' },
    { property: 'og:title', content: title },
    { property: 'og:description', content: description },
  ]
  if (origin === null) return { meta, links: [] }
  const url = `${origin}${import.meta.env.BASE_URL}`
  return {
    meta: [
      ...meta,
      { property: 'og:url', content: url },
      { property: 'og:image', content: `${origin}${asset('mascot/social.png')}` },
      { name: 'twitter:card', content: 'summary' },
    ],
    links: [{ rel: 'canonical', href: url }],
  }
}

/** The head of the page for an address nothing answers: it names no address of its own, since it is served at every one of them, and asks search engines to leave it out. */
export function notFoundHead(origin: string | null = __SITE_ORIGIN__): Head {
  const { meta, links } = pageHead('Page not found: tagents', DESCRIPTION, origin)
  return {
    meta: [
      ...meta.filter((entry) => !('property' in entry && entry.property === 'og:url')),
      { name: 'robots', content: 'noindex' },
    ],
    links: links.filter(({ rel }) => rel !== 'canonical'),
  }
}
