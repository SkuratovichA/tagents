// @tagents/telegram — the Bot API, typed and small. One client, the methods a
// bot actually uses, and the 4096-character split. No i18n: nothing in here
// ever speaks to a person.
export { TelegramError } from './errors.ts';

export {
  DEFAULT_TIMEOUT_MS,
  POLL_TIMEOUT_SLACK_MS,
  TELEGRAM_API_BASE,
  TYPING_INTERVAL_MS,
  createTelegram,
} from './client.ts';
export type {
  CallOptions,
  GetUpdatesOptions,
  SendOptions,
  Telegram,
  TelegramOptions,
} from './client.ts';

export { EnvelopeSchema, MessageSchema, UpdateSchema, UpdatesSchema, UserSchema } from './schemas.ts';
export type { TgEnvelope, TgMessage, TgUpdate, TgUser } from './schemas.ts';

export { TG_TEXT_LIMIT, splitMessage } from './split.ts';
