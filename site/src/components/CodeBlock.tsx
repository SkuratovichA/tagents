interface CodeBlockProps {
  /** What the code is, for a screen reader: a block that scrolls sideways is a region of its own. */
  label: string
  children: string
}

/** Code the visitor copies by hand: it scrolls sideways on a narrow screen and can be reached by keyboard. */
export function CodeBlock({ label, children }: CodeBlockProps) {
  return (
    <pre className="code" role="region" tabIndex={0} aria-label={label}>
      <code>{children}</code>
    </pre>
  )
}
