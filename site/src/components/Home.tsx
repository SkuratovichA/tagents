import {
  DEMO_COPY,
  EXTRAS,
  FEATURES,
  INSTALL,
  LEAD,
  PITCH,
  RESURRECT,
  SETTINGS_JSON,
  SITE_NAME,
} from '../content'
import { DEMOS } from '../demos'
import { GITHUB_URL } from '../lib/site'
import type { Scene } from '../lib/screen'
import { Mascot } from '../mascot'
import { CodeBlock } from './CodeBlock'
import { Demo } from './Demo'

function sceneOf(id: Scene['id']): Scene {
  const scene = DEMOS.find((candidate) => candidate.id === id)
  if (scene === undefined) throw new Error(`no recorded demo named ${id}`)
  return scene
}

export function Home() {
  const [first, ...more] = DEMO_COPY
  return (
    <>
      <section className="container hero" id="top">
        <div>
          <h1 className="hero__title">{SITE_NAME}</h1>
          <p className="hero__pitch">{PITCH}</p>
          <p className="hero__lead">{LEAD}</p>
          <div className="hero__actions">
            <a className="button" href="#install">
              Install
            </a>
            <a className="button button--ghost" href={GITHUB_URL}>
              View on GitHub
            </a>
          </div>
        </div>
        <Mascot />
      </section>

      <section className="container section" id="demo" aria-labelledby="demo-title">
        <h2 id="demo-title">See it work</h2>
        {first && <Demo scene={sceneOf(first.scene)} title={first.title} caption={first.caption} />}
      </section>

      <section className="container section" aria-labelledby="does-title">
        <h2 id="does-title">What it does</h2>
        <ul className="points">
          {FEATURES.map((feature) => (
            <li key={feature.title} className="card">
              <h3>{feature.title}</h3>
              <p>{feature.text}</p>
            </li>
          ))}
        </ul>
      </section>

      <section className="container section" aria-labelledby="closer-title">
        <h2 id="closer-title">A closer look</h2>
        {more.map((copy) => (
          <Demo
            key={copy.scene}
            scene={sceneOf(copy.scene)}
            title={copy.title}
            caption={copy.caption}
          />
        ))}
      </section>

      <section className="container section" aria-labelledby="resurrect-title">
        <h2 id="resurrect-title">{RESURRECT.title}</h2>
        <p className="section__intro">{RESURRECT.text}</p>
        <p>{RESURRECT.setup}</p>
        <CodeBlock label="Lines for the tmux config">{RESURRECT.tmuxConf}</CodeBlock>
        <p>{RESURRECT.without}</p>
      </section>

      <section className="container section" id="install" aria-labelledby="install-title">
        <h2 id="install-title">{INSTALL.title}</h2>
        <ol className="steps">
          <li>
            <p>{INSTALL.intro}</p>
            <CodeBlock label="Install command">{INSTALL.command}</CodeBlock>
            <p>{INSTALL.where}</p>
          </li>
          <li>
            <p>{INSTALL.hooksIntro}</p>
            <details className="fold">
              <summary>{INSTALL.hooksSummary}</summary>
              <CodeBlock label="The hooks and the status line for settings.json">
                {SETTINGS_JSON}
              </CodeBlock>
            </details>
            <p>{INSTALL.hooksNote}</p>
          </li>
          <li>
            <p>{INSTALL.startIntro}</p>
            <CodeBlock label="Start command">{INSTALL.start}</CodeBlock>
          </li>
        </ol>
      </section>

      <section className="container section" aria-labelledby="extras-title">
        <h2 id="extras-title">{EXTRAS.title}</h2>
        <div className="extras">
          <div className="card">
            <h3>{EXTRAS.notifications.title}</h3>
            <p>{EXTRAS.notifications.text}</p>
            <CodeBlock label="Notification commands">{EXTRAS.notifications.commands}</CodeBlock>
          </div>
          <div className="card">
            <h3>{EXTRAS.statusBar.title}</h3>
            <p>{EXTRAS.statusBar.text}</p>
            <CodeBlock label="Line for the tmux config">{EXTRAS.statusBar.command}</CodeBlock>
          </div>
          <div className="card">
            <h3>{EXTRAS.plugin.title}</h3>
            <p>{EXTRAS.plugin.text}</p>
            <CodeBlock label="Plugin command">{EXTRAS.plugin.command}</CodeBlock>
          </div>
        </div>
      </section>
    </>
  )
}
