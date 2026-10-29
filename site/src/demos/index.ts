import type { Scene } from '../lib/screen.ts'
import { closed } from './data/closed.ts'
import { hero } from './data/hero.ts'
import { keys } from './data/keys.ts'
import { newChat } from './data/new-chat.ts'

/** Every recorded demo. */
export const DEMOS: readonly Scene[] = [hero, keys, newChat, closed]
