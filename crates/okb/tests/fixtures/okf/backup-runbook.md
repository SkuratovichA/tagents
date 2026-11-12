---
type: Runbook
title: Nightly backup run
description: How the nightly backup runs and how to restore it.
tags: [backup, ops]
generated:
  by: backup-tool
  at: 2026-09-10T08:00:00Z
sources:
  - resource: https://example.invalid/backup-docs
    title: Backup tool manual
status: stable
---

The nightly job copies the data volume to a second disk.

## Run

Start it by hand with `make backup`. The retention rules live in [the cache policy](/cache-policy.md#retention).

```sh
# links in code are not links: [[no-such-doc]] and [gone](/no-such-doc.md)
make backup
```

## Restore

Restore the newest copy first. The reasoning is in [[cache-policy#Retention]].
