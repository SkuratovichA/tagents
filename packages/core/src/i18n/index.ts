// i18next with the resources inlined: no files to ship, no async load before
// the first line of output. One namespace ('core'), because the only strings
// that go through it are the CLI's own.
//
// TAGENTS_LOCALE picks the language; anything unknown falls back to English.
// JSON output and the sessions.* text are NOT translated — they are contracts.
import { createInstance, type i18n as I18n, type TFunction } from 'i18next';
import { en } from './en.ts';
import { ru } from './ru.ts';

export const DEFAULT_LOCALE = 'en';
export const resources = { en: { core: en }, ru: { core: ru } } as const;
export type Locale = keyof typeof resources;
export type CoreResource = typeof en;

// Core's own keys are checked HERE, not through i18next's CustomTypeOptions:
// a library must not augment that global interface. Its .d.ts would carry the
// augmentation into every consumer that shares the i18next instance (which is
// every real install — only a link: dependency keeps two copies) and retype
// THEIR t() to core's keys with core's default namespace. The plugin-facing
// PluginContext.t stays i18next's own permissive TFunction on purpose.
export type CoreKey = keyof CoreResource & string;
export type CoreVars = Record<string, string | number>;
export type CoreT = (key: CoreKey, vars?: CoreVars) => string;

/** Key-checked view over a TFunction for core's own call sites. */
export function coreT(t: TFunction): CoreT {
  // No explicit undefined: i18next types its arguments as a tuple with an
  // optional element, which exactOptionalPropertyTypes refuses to fill with one.
  return (key, vars) => String(vars === undefined ? t(key) : t(key, vars));
}

export function isLocale(v: string | undefined): v is Locale {
  return v === 'en' || v === 'ru';
}

/** A fresh instance per call: a library must not own a global. */
export function createI18n(locale: string | undefined = process.env['TAGENTS_LOCALE']): I18n {
  const lng = isLocale(locale) ? locale : DEFAULT_LOCALE;
  const i18n = createInstance();
  void i18n.init({
    lng,
    fallbackLng: DEFAULT_LOCALE,
    defaultNS: 'core',
    ns: ['core'],
    resources,
    interpolation: { escapeValue: false },
    // i18next prints a sponsor line through console.info on the first init.
    // stdout here is a contract (one JSON document, or bytes an oracle pins),
    // so a library writing to it uninvited would break every JSON verb.
  });
  return i18n;
}

export function createT(locale?: string): TFunction {
  return createI18n(locale).t;
}
