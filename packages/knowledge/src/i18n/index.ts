// The same i18n approach core uses — one namespace ('knowledge'), en + ru
// inlined, TAGENTS_LOCALE picks the language, anything unknown falls back to
// English — but NOT i18next.
//
// Why not: i18next's key typing comes from a `declare module 'i18next'`
// augmentation, and @tagents/core already ships one that pins
// CustomTypeOptions to `{ core: CoreResource }`. A second augmentation cannot
// merge (TS2717: the same property declared twice), so inside a package that
// imports core, every `t('somethingOfOurs')` is a type error. A dozen lines of
// interpolation keep the strings typed exactly, which was the point of the
// library here anyway.
import { en } from './en.ts';
import { ru } from './ru.ts';

export const DEFAULT_LOCALE = 'en';
export const resources = { en: { knowledge: en }, ru: { knowledge: ru } } as const;
export type Locale = keyof typeof resources;
export type KnowledgeResource = typeof en;
export type KnowledgeKey = keyof KnowledgeResource;
export type Vars = Readonly<Record<string, string | number>>;
/** Same call shape as i18next's `t`: a key, and the values its {{slots}} take. */
export type Translate = (key: KnowledgeKey, vars?: Vars) => string;

export function isLocale(v: string | undefined): v is Locale {
  return v === 'en' || v === 'ru';
}

const SLOT = /\{\{(\w+)\}\}/g;

export function interpolate(template: string, vars: Vars): string {
  return template.replace(SLOT, (whole, name: string) => {
    const value = vars[name];
    return value === undefined ? whole : String(value);
  });
}

/** A fresh translator per call: a library must not own a global. */
export function createT(locale: string | undefined = process.env['TAGENTS_LOCALE']): Translate {
  const lng = isLocale(locale) ? locale : DEFAULT_LOCALE;
  const table = resources[lng].knowledge;
  return (key, vars) => interpolate(table[key] ?? en[key], vars ?? {});
}
