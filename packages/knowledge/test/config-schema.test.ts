// schemas/config.schema.json describes the `knowledge` table for editors; this
// package reads it with the zod schema below. Nothing else keeps the two the
// same, so this does.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { z } from 'zod';
import { ConfigSchema } from '../src/paths.ts';

const SCHEMA_FILE = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..', 'schemas', 'config.schema.json');

const TableSchema = z.looseObject({
  properties: z.record(z.string(), z.looseObject({ type: z.string() })),
  required: z.array(z.string()).optional(),
  additionalProperties: z.unknown().optional(),
});
const FileSchema = z.looseObject({ properties: z.looseObject({ knowledge: TableSchema }) });
const described = FileSchema.parse(JSON.parse(fs.readFileSync(SCHEMA_FILE, 'utf8'))).properties.knowledge;
const read = FileSchema.parse(z.toJSONSchema(ConfigSchema, { io: 'input' })).properties.knowledge;

test('the knowledge table the schema describes has the keys, types and required keys this package reads', () => {
  assert.deepEqual(
    Object.entries(described.properties).map(([key, node]) => [key, node.type]),
    Object.entries(read.properties).map(([key, node]) => [key, node.type])
  );
  assert.deepEqual(described.required ?? [], read.required ?? []);
});

test('like the reader, the schema lets other keys sit in the table', () => {
  assert.notEqual(described.additionalProperties, false);
  assert.ok(ConfigSchema.safeParse({ knowledge: { dir: '~/notes', someday: true } }).success);
});
