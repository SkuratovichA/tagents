// Every string a person reads in a banner, in one typed table.
//
// Not i18next and `ctx.t`, though the rest of tagents uses them: core's
// `declare module 'i18next'` augmentation pins the key union to core's own keys,
// and a second package cannot add its own (TS2717, no merging), so every
// `t('ownKey')` in a plugin is a type error. A table of strings and small
// functions is checked by the compiler for the keys and the arguments both, and
// there is no `{{slot}}` syntax to get wrong.
import { DEFAULT_LOCALE, isLocale, type Locale } from '@tagents/core';

export interface Phrases {
  readonly kindQuestion: string;
  readonly kindPlan: string;
  readonly kindPermission: string;
  readonly kindTurnDone: string;
  readonly kindCacheExpiring: string;
  readonly kindSessionEnd: string;
  /** Body of a question that came with no text. */
  readonly questionBody: string;
  /** Body of a finished turn whose answer could not be read. */
  readonly turnDoneBody: string;
  /** Body of a permission prompt that came with no message. */
  readonly permissionBody: string;
  /** Body of a session end that came with no reason. */
  readonly sessionEndBody: string;
  /** `leftMin` is whole minutes; below one the sentence says "within a minute", never "~0 min". */
  readonly cacheBody: (idleMin: number, leftMin: number) => string;
}

const en: Phrases = {
  kindQuestion: 'Asks you something',
  kindPlan: 'Plan ready for review',
  kindPermission: 'Needs your permission',
  kindTurnDone: 'Answer ready',
  kindCacheExpiring: 'Prompt cache expiring',
  kindSessionEnd: 'Session ended',
  questionBody: 'Asking you something',
  turnDoneBody: 'Your move',
  permissionBody: 'Waiting for your permission',
  sessionEndBody: 'No reason given',
  cacheBody: (idleMin, leftMin) =>
    `Idle ${idleMin} min — send anything within ${leftMin < 1 ? 'a minute' : `~${leftMin} min`} to keep the prompt cache`,
};

const ru: Phrases = {
  kindQuestion: 'Задаёт вопрос',
  kindPlan: 'План готов к проверке',
  kindPermission: 'Нужно ваше разрешение',
  kindTurnDone: 'Ответ готов',
  kindCacheExpiring: 'Кэш промпта истекает',
  kindSessionEnd: 'Сессия завершена',
  questionBody: 'Хочет что-то спросить',
  turnDoneBody: 'Ваш ход',
  permissionBody: 'Ждёт вашего разрешения',
  sessionEndBody: 'Причина не указана',
  cacheBody: (idleMin, leftMin) =>
    `Простой ${idleMin} мин — отправьте что угодно в течение ${leftMin < 1 ? 'минуты' : `~${leftMin} мин`}, чтобы сохранить кэш промпта`,
};

const TABLE: Readonly<Record<Locale, Phrases>> = { en, ru };

export function phrasesFor(locale: Locale): Phrases {
  return TABLE[locale];
}

/** The table for `TAGENTS_LOCALE`, English when it is unset or not one we speak. */
export function currentPhrases(env: NodeJS.ProcessEnv = process.env): Phrases {
  const v = env['TAGENTS_LOCALE'];
  return phrasesFor(isLocale(v) ? v : DEFAULT_LOCALE);
}
