import { asset } from '../lib/base'

/** Shown for an address nothing answers, and prerendered at /404 for the host's 404.html. */
export function NotFoundPage() {
  return (
    <section className="container not-found">
      <p className="not-found__code">404</p>
      <h1>This page is not here</h1>
      <p>The address leads nowhere. The whole site is one page.</p>
      <div className="not-found__links">
        <a href={asset('')} className="button">
          Back to the start
        </a>
      </div>
    </section>
  )
}
