// A JSON value, and the guards that make an `unknown` one without an assertion. Everything the generator reads from outside the type system — an MCP tool's schema, plugin.json, the contract.json already on disk — crosses here.

import { createT } from './i18n/index.ts';

export type JsonValue = null | boolean | number | string | readonly JsonValue[] | JsonObject;

export interface JsonObject {
  readonly [key: string]: JsonValue;
}

export function isJsonValue(v: unknown): v is JsonValue {
  if (v === null || typeof v === 'boolean' || typeof v === 'string') return true;
  if (typeof v === 'number') return Number.isFinite(v);
  if (Array.isArray(v)) return v.every(isJsonValue);
  if (typeof v === 'object') return Object.values(v).every(isJsonValue);
  return false;
}

export function isJsonArray(v: JsonValue | undefined): v is readonly JsonValue[] {
  return Array.isArray(v);
}

export function isJsonObject(v: JsonValue | undefined): v is JsonObject {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

/** Throws a SyntaxError when `text` is not JSON. */
export function parseJson(text: string): JsonValue {
  const parsed: unknown = JSON.parse(text);
  if (!isJsonValue(parsed)) throw new SyntaxError(createT()('notJsonValue'));
  return parsed;
}

/** Any value that survives a JSON round trip, as a JsonValue. */
export function toJson(v: unknown): JsonValue {
  return parseJson(JSON.stringify(v));
}

/** Two-space JSON with a trailing newline: the form every generated JSON file is written in. */
export function stringifyJson(v: JsonValue): string {
  return `${JSON.stringify(v, null, 2)}\n`;
}
