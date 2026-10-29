import { SITE_NAME } from '../content'
import { asset } from '../lib/base'
import { GITHUB_URL } from '../lib/site'
import { ThemeToggle } from './ThemeToggle'

export function Header() {
  return (
    <header className="site-header">
      <div className="container site-header__inner">
        <a href={asset('')} className="brand">
          <img
            className="brand__icon"
            src={asset('mascot/favicon-64.png')}
            width={24}
            height={24}
            alt=""
          />
          <span>{SITE_NAME}</span>
        </a>
        <nav className="site-nav" aria-label="Page">
          <a className="site-nav__section" href={`${asset('')}#demo`}>
            Demo
          </a>
          <a className="site-nav__section" href={`${asset('')}#install`}>
            Install
          </a>
          <a href={GITHUB_URL}>GitHub</a>
          <ThemeToggle />
        </nav>
      </div>
    </header>
  )
}
