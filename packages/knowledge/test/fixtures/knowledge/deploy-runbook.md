---
id: deploy-runbook
title: Deploying the demo service
kind: runbook
tags: [deploy, ci]
updated: 2026-09-10
scope: project
---

The demo service runs behind a single reverse proxy. Everything below assumes
you are on the build host and the working tree is clean.

## Before you start

Check that the test suite is green and that nobody else is mid-release. A
release that races another one leaves the proxy pointing at a build that was
never tagged.

## Deploy

```sh
# comments in here start with ## and must NOT split the section
## pick the tag first
make release TAG=v1.2.3
```

The build writes a manifest next to the artefact.

## Rollback

Point the proxy back at the previous manifest and restart it. No database
migration is ever undone automatically; see [[sqlite-over-vectors]] for why the
index is a throwaway.
