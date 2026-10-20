## 1. Plist association

- [x] 1.1 Read the helper app's bundle id at install time and write it as the associated id, falling back to the base id; proved by `pnpm --filter @tagents/notify test` (test/launchd.test.ts: the `install with an app` and `install without an app` tests)
- [x] 1.2 Keep the label, plist path and launchctl target on the base id; proved by the same suite (`renderPlist writes the associated id ...`)
- [x] 1.3 Pass the app from the macOS platform and none from the log backend; proved by `pnpm --filter @tagents/notify typecheck`

## 2. Documentation

- [x] 2.1 Correct the comment on the bundle id constant in paths.ts
