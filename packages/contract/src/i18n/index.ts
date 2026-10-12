// A typed t() built on the interpolation @tagents/knowledge already ships — not on i18next, whose key typing comes from a global `declare module` that cannot be augmented a second time (see packages/knowledge/src/i18n/index.ts and LEARNING.md). Imported from the source file, not the package name: the package name is a built dist, and importing its index would load the SQLite and MCP modules just to interpolate a string.
import { DEFAULT_LOCALE, interpolate, isLocale, type Vars } from '../../../knowledge/src/i18n/index.ts';
import { en } from './en.ts';
import { ru } from './ru.ts';

const resources = { en, ru } as const;

export type ContractKey = keyof typeof en;
/** Same call shape as i18next's `t`: a key, and the values its {{slots}} take. */
export type Translate = (key: ContractKey, vars?: Vars) => string;

/** A fresh translator per call; TAGENTS_LOCALE picks the language, anything unknown falls back to English. */
export function createT(locale: string | undefined = process.env['TAGENTS_LOCALE']): Translate {
  const table: Readonly<Record<ContractKey, string>> = resources[isLocale(locale) ? locale : DEFAULT_LOCALE];
  return (key, vars) => interpolate(table[key], vars ?? {});
}
