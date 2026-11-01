// The messages section of the plugin vectors: what the CLI's i18next prints for every key of both catalogues with sample values, and which language a `TAGENTS_LOCALE` selects.
//
// The Rust verbs read `spec/cli/messages.json` and interpolate `{{name}}` themselves, so these cases are the proof that a value that holds `{{x}}`, `$t(pluginNone)` or the name of another variable prints as typed, and that a key missing in `ru` prints the English text.
import { coreT, createT, type CoreKey } from '../../packages/core/src/i18n/index.ts';
import { en } from '../../packages/core/src/i18n/en.ts';
import { ru } from '../../packages/core/src/i18n/ru.ts';

/** Names i18next gives a meaning of its own when they are passed as options; a catalogue text using one would not be plain interpolation. */
const RESERVED = new Set(['lng', 'lngs', 'ns', 'context', 'defaultValue', 'replace', 'ordinal', 'joinArrays', 'postProcess', 'interpolation', 'keySeparator', 'nsSeparator', 'returnObjects', 'returnDetails', 'skipInterpolation', 'fallbackLng']);

type Vars = Record<string, string | number>;

const variablesOf = (text: string): string[] => [...new Set([...text.matchAll(/\{\{(\w+)\}\}/g)].map((m) => m[1] ?? ''))];

/** The value sets tried for a key whose text has these variables. */
function valueSets(names: readonly string[]): Vars[] {
  if (names.length === 0) return [{}];
  const all = (make: (name: string, index: number) => string | number): Vars => Object.fromEntries(names.map((name, i) => [name, make(name, i)]));
  const sets: Vars[] = [
    all((name) => `<${name}>`),
    all(() => '{{x}}'),
    all(() => '$t(pluginNone)'),
    all(() => ''),
    all(() => 'é\u{1F600} $1 $& {{'),
    all((_, i) => `a${i}`),
  ];
  // The first variable holds the placeholder of the second: it must not be filled in again.
  if (names.length > 1) sets.push(all((_, i) => (i === 0 ? `{{${names[1]}}}` : `second-${i}`)));
  if (names.includes('count')) sets.push(all((name) => (name === 'count' ? 0 : 'v')), all((name) => (name === 'count' ? 1 : 'v')), all((name) => (name === 'count' ? 12 : 'v')));
  return sets;
}

export function messagesVectors(): unknown {
  const cases: Array<{ locale: 'en' | 'ru'; key: string; vars: Vars; text: string }> = [];
  for (const locale of ['en', 'ru'] as const) {
    const t = coreT(createT(locale));
    // A key `ru` does not have prints in English, so every key of `en` is tried in both.
    for (const key of Object.keys(en)) {
      const text = (locale === 'ru' ? (ru as Record<string, string>)[key] : undefined) ?? en[key as keyof typeof en];
      const names = variablesOf(text);
      for (const name of names) if (RESERVED.has(name)) throw new Error(`${locale}.${key} uses {{${name}}}, which i18next reads as an option`);
      for (const vars of valueSets(names)) cases.push({ locale, key, vars, text: t(key as CoreKey, vars) });
    }
  }
  const missingInRu = Object.keys(en).filter((key) => !(key in ru));
  const locales = ['en', 'ru', 'EN', 'ru-RU', 'de', '', ' ru', 'ru ', 'en-US', 'fr'];
  return {
    cases,
    missingInRu,
    locales: [...locales, null].map((value) => ({
      value,
      text: coreT(createT(value ?? undefined))('pluginRemoved', { name: 'n', file: 'f' }),
    })),
  };
}
