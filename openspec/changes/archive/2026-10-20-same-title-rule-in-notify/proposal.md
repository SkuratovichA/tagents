## Why

The glyph rule changed in `keep-non-ascii-title-words`: a one-letter word in another alphabet is kept. The notify package holds a TypeScript copy of the rule and it still dropped `я` from `я иду`, so a notice named the agent differently from the dashboard. The test that pins the copy to the shell had no title that told the two rules apart.

## What Changes

- The title of a notice drops the first word only when it is one code point and a symbol, the same rule as the dashboard.
- The notify spec states the rule with a status glyph and a one-letter word; the dashboard-list spec gains the one-letter word scenario.

## Impact

- Affected specs: `notify`, `dashboard-list`.
- Affected code: `packages/notify/src/compose.ts`, `packages/notify/test/compose.test.ts`.
