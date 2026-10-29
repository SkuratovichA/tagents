import { MASCOT } from '../mascot'
import { DOCS_URL, GITHUB_URL } from '../lib/site'

export function Footer() {
  return (
    <footer className="site-footer">
      <div className="container site-footer__inner">
        <p>{MASCOT.credit}</p>
        <nav aria-label="Elsewhere">
          <a href={GITHUB_URL}>GitHub</a>
          <a href={DOCS_URL}>Docs</a>
        </nav>
      </div>
    </footer>
  )
}
