# The Claude Code plugin

The sessions the dashboard watches can also know how to use it. This repository is a Claude Code plugin, and its own marketplace, that gives a session two things: a skill with the exact contract of the tagents tools, and an MCP server over your markdown notes.

## Install

```
/plugin install tagents --marketplace SkuratovichA/tagents
```

That one line needs Claude Code 2.1.275 or later. Before it, use two commands:

```
/plugin marketplace add SkuratovichA/tagents
/plugin install tagents@tagents
```

## What it adds

### The `tagents` skill

The skill gives Claude the exact contract of `tagents-core`, `tagents-knowledge`, `tagents`, `tusage` and `tnotes`: every verb and flag, every MCP tool schema, and the public TypeScript API. It is generated from the code, so it never goes stale ([how](../architecture/contract)). Claude loads it when a task touches tagents instead of guessing at flags.

### The `knowledge` MCP server

The server gives every session search and read access to your markdown notes (`tagents-knowledge`). The plugin registers `packages/knowledge/bin/knowledge-mcp` for it.

- It asks `tagents-knowledge serve` for the unix socket of **one shared knowledge server per environment** and joins the session to it with `nc -U`. That keeps a session at about 1.4 MB instead of a 30 MB node process.
- The server starts on demand and exits after 10 minutes without a client.
- If `serve` fails, a checkout predates it, or there is no `nc`, the script runs `tagents-knowledge mcp` as before.
- `tagents-knowledge` has to be on `$PATH`.

::: warning A hand-registered server appears twice
If that server is already registered by hand with `claude mcp add`, remove the hand-made entry or its tools appear twice.
:::

## What it does not do

The plugin registers no hooks and no status line. The state hook and the status line stay [steps of the install](./getting-started#tell-claude-code-about-it), because a plugin cannot set a status line.

## Where the rest is documented

- [The generated contract](../architecture/contract), for how the skill is kept honest.
- [`@tagents/knowledge`](https://github.com/SkuratovichA/tagents/blob/main/packages/knowledge/README.md), for the notes documents and the FTS5 index behind the server.
