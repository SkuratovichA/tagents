// The slices of the Bot API this package parses.
//
// Every object is a `looseObject`: Telegram adds fields, a bot's event log
// stores whole updates and replays them, and an exact schema would drop what it
// did not know about. Only the fields something reads are typed; the rest
// survives untouched.
import { z } from 'zod';

const ChatSchema = z.looseObject({
  id: z.number(),
  type: z.string().optional(),
  title: z.string().optional(),
});

/** One incoming message, in the shape the runners read it. */
export const MessageSchema = z.looseObject({
  message_id: z.number(),
  chat: ChatSchema,
  message_thread_id: z.number().optional(),
  from: z.looseObject({ id: z.number().optional() }).optional(),
  text: z.string().optional(),
  caption: z.string().optional(),
  voice: z.looseObject({ duration: z.number() }).optional(),
  video_note: z.looseObject({ duration: z.number() }).optional(),
  photo: z.array(z.looseObject({ file_id: z.string() })).optional(),
  document: z.looseObject({ file_id: z.string(), file_name: z.string().optional() }).optional(),
  reply_to_message: z.looseObject({ message_id: z.number(), text: z.string().optional() }).optional(),
  // Unix SECONDS. `date` is when the sender actually sent it, which is not when
  // a turn reads it — a burst waits out a settle window and a slow turn runs for
  // tens of minutes. `edit_date` is present only on an edited message, and
  // Telegram announces an edit no other way.
  date: z.number().optional(),
  edit_date: z.number().optional(),
});
export type TgMessage = z.infer<typeof MessageSchema>;

/**
 * One update. A message that fails to parse is dropped to `undefined` rather
 * than taking the whole batch down: the offset still has to move past it, and a
 * batch that throws is a poll loop that never advances.
 */
export const UpdateSchema = z.looseObject({
  update_id: z.number(),
  message: MessageSchema.optional().catch(undefined),
});
export type TgUpdate = z.infer<typeof UpdateSchema>;

/** A `getUpdates` result. Anything unparseable reads as an empty batch. */
export const UpdatesSchema = z.array(UpdateSchema).catch([]);

/** What `getMe` answers with. */
export const UserSchema = z
  .looseObject({
    id: z.number().optional(),
    is_bot: z.boolean().optional(),
    username: z.string().optional(),
    first_name: z.string().optional(),
  })
  .catch({});
export type TgUser = z.infer<typeof UserSchema>;

/**
 * The Bot API envelope: `ok` with a `result`, or `ok: false` with the API's own
 * `error_code` and `description`.
 *
 * `.catch({})` is deliberate. A body that is not an envelope at all — an HTML
 * error page from a proxy, a truncated read — becomes an empty object, which is
 * not ok, which is a `TelegramError` naming the method. A parse failure here
 * would throw something with no method in it.
 */
export const EnvelopeSchema = z
  .looseObject({
    ok: z.boolean().optional(),
    error_code: z.union([z.number(), z.string()]).optional(),
    description: z.string().optional(),
    result: z.unknown().optional(),
  })
  .catch({});
export type TgEnvelope = z.infer<typeof EnvelopeSchema>;
