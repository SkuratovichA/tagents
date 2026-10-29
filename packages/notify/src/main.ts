#!/usr/bin/env node
// The package's own bin: `tagents-notify <verb>`, and what the LaunchAgent runs
// (`node dist/main.js run`). The verbs need no entry in the config here, so
// a service started by launchd works on a machine where the host never ran.
import fs from 'node:fs';
import { pathToFileURL } from 'node:url';
import { runPluginBin } from '@tagents/core';
import plugin from './plugin.ts';

// Only when this file is the entry: importing it, as a test does, runs nothing.
const invokedAs = process.argv[1] ? pathToFileURL(fs.realpathSync(process.argv[1])).href : '';
if (invokedAs === import.meta.url) {
  process.exitCode = await runPluginBin(plugin);
}
