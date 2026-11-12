---
type: Decision
title: Cache policy
description: Why cache entries expire after a day.
tags: [cache]
generated:
  by: platform-team
  at: 2026-09-12T10:00:00+02:00
stale_after: 2026-10-01T00:00:00+02:00
---

Entries expire after one day.

## Decision

Short lifetimes keep the cache honest. A failover to the standby node empties it anyway.

## Retention

Backups are kept for a week, see [the nightly backup](./backup-runbook.md).
