// The notify plugin: what the host sees.
//
// Registering it in config.yaml gives `tagents notify <verb>`. The service that
// actually posts notifications runs under its own LaunchAgent (see service.ts),
// so a host that merely lists plugins never starts it.
import { definePlugin } from '@tagents/core';

export default definePlugin({
  name: 'notify',
  apiVersion: 1,
});
