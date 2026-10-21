## Why

The helper app built with an icon gets a bundle id of its own, `io.github.skuratovicha.tagents-notify.i<8 hex>`, but the LaunchAgent plist always associated the job with the base id, so Login Items filed the job under an id no installed app has.

## What Changes

- The plist's `AssociatedBundleIdentifiers` names the bundle id the installed helper app really has, read from the app at install time, and the base id when there is no app or it cannot be read.
- The label, the plist's path and the `launchctl` target stay on the base id, so a new icon never leaves the old job registered.
- The "What launchd runs" requirement drops its claim that the label is what Login Items uses, and a new requirement states the association.

## Capabilities

### New Capabilities

### Modified Capabilities

- `notify-service`: "What launchd runs" is restated without the associated-id sentence, and "The job is filed under the app in Login Items" is added.

## Impact

- `packages/notify/src/platform/macos/launchd.ts`, `packages/notify/src/platform/index.ts` and the comment in `packages/notify/src/paths.ts`.
- `packages/notify/test/launchd.test.ts`.
- The plist an install writes differs from before only when the app was built with an icon.
