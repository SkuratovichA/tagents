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

declare module 'i18next' {
  interface CustomTypeOptions {
    defaultNS: 'core';
    resources: { core: CoreResource };
  }
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
    initImmediate: false,
    // i18next prints a sponsor line through console.info on the first init.
    // stdout here is a contract (one JSON document, or bytes an oracle pins),
    // so a library writing to it uninvited would break every JSON verb.
    showSupportNotice: false,
  });
  return i18n;
}

export function createT(locale?: string): TFunction {
  return createI18n(locale).t;
}
