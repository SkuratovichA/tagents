// The public surface of @tagents/notify: the plugin itself, and the types a new
// notification backend is written against. The host does not come through
// here: it imports the plugin from the "tagents" entry in package.json.
export { default } from './plugin.ts';
