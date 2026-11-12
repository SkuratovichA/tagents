---
id: sqlite-over-vectors
title: Why this index is SQLite FTS5 and not a vector store
kind: decision
tags: [search, sqlite]
updated: 2026-09-11
---

The corpus is a few dozen small documents that one person writes by hand.

## The decision

Full-text search over the sections beats embeddings here: there is no scale to
amortise an embedding pipeline over, and an exact word is what the author
actually looks for.

## What it costs

No synonym or morphology matching. A query has to use a word the document uses,
which is a real limitation and an acceptable one at this size.
