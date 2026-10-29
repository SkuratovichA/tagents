import type { Scene } from './lib/screen'

export const SITE_NAME = 'tagents'
export const TITLE = 'tagents: know which Claude Code session needs you'
export const PITCH = 'Know which Claude Code session needs you, without leaving tmux.'
export const DESCRIPTION =
  'A tmux dashboard for your Claude Code chats: what each one is doing, which one is waiting on you, and what it has spent.'
export const LEAD =
  'A live dashboard for every Claude Code chat you run in tmux: what each one is doing, which one is waiting on you, how much context it holds and what it has spent.'

export interface Feature {
  readonly title: string
  readonly text: string
}

// Worded as the README words them.
export const FEATURES: readonly Feature[] = [
  {
    title: 'Shows who is waiting on you',
    text: 'A chat stuck on a question or a permission turns BLOCKED and is counted in its project’s header, so nothing waits unnoticed in a window you are not looking at.',
  },
  {
    title: 'Taps you on the shoulder',
    text: 'A desktop notification when a chat asks something, wants a permission or finishes its turn; click it and you land in that chat.',
  },
  {
    title: 'The chat beside the list',
    text: 'The dashboard is a tmux session of its own: enter on a row shows that chat on the right, and ctrl-g takes your terminal to where it lives.',
  },
  {
    title: 'Survives a reboot',
    text: 'Close the laptop, restart, kill the tmux server: every chat comes back in its window, on its account, with its model.',
  },
  {
    title: 'Forgets nothing',
    text: 'Closed chats stay one keystroke away, with their last prompts, and resume where they ran.',
  },
  {
    title: 'Keeps your accounts apart',
    text: 'Work and personal Claude logins, chosen per directory, with a badge on every row so you always know which one is paying.',
  },
  {
    title: 'Counts the cost',
    text: 'Context size and spend per chat, what each project burned in the last five hours, and the month so far against your plan’s limit.',
  },
]

export interface DemoCopy {
  /** The id of the recorded scene. */
  readonly scene: Scene['id']
  readonly title: string
  /** What the recording shows, in a sentence. */
  readonly caption: string
}

export const DEMO_COPY: readonly DemoCopy[] = [
  {
    scene: 'hero',
    title: 'The dashboard',
    caption:
      'Five chats in four projects. One stops to ask for a permission, the list marks it BLOCKED, and enter shows its chat beside the list.',
  },
  {
    scene: 'keys',
    title: 'Every key, in one list',
    caption:
      'Press ? for every key. Pick one from the list and enter runs it, so there is nothing to memorise.',
  },
  {
    scene: 'new-chat',
    title: 'A new chat where the cursor is',
    caption:
      'ctrl-n starts a new chat in the project under the cursor: a row appears in the list and the chat opens beside it.',
  },
  {
    scene: 'closed',
    title: 'Closed chats come back',
    caption: 'ctrl-y lists the chats that were closed. Pick one and it resumes where it ran.',
  },
]

export const RECORDED_WITH = 'Recorded from the real dashboard, with made-up chats.'

export const RESURRECT = {
  title: 'Never lose a session',
  text: 'tmux-resurrect and tmux-continuum bring back your sessions, windows and splits, but a chat comes back as an empty shell: they cannot know which conversation it was. tagents remembers, and resumes each one in its place, on the account it ran on, with its model and its window name.',
  setup: 'Add two lines to ~/.tmux.conf, after the tmux-resurrect settings:',
  tmuxConf: `set -g @resurrect-hook-post-save-layout '~/.local/bin/tagents --resurrect-save'
set -g @resurrect-hook-post-restore-all '~/.local/bin/tagents --resurrect --auto'`,
  without: 'Without tmux-resurrect it still works: tagents --resurrect rebuilds what is missing.',
} as const

export const INSTALL = {
  title: 'Install',
  intro: 'One command. It needs tmux, fzf, jq, git, Node 22.18+ and pnpm.',
  command: 'curl -fsSL https://raw.githubusercontent.com/SkuratovichA/tagents/main/install.sh | sh',
  where:
    'It puts one managed copy in ~/.local/share/tagents, the commands in ~/.local/bin and the Claude Code hooks in ~/.claude/hooks. Run it again, or tagents update, to update.',
  hooksIntro: 'Then tell Claude Code about the hooks. Add this to ~/.claude/settings.json:',
  hooksSummary: 'settings.json',
  hooksNote:
    'The hook is how a chat tells tagents what it is doing; the status line is where the model column comes from.',
  startIntro:
    'Then run it inside any tmux session. Every Claude chat with the hook shows up on its own, whether tagents started it or you typed claude in a pane yourself.',
  start: 'tagents',
} as const

// The README's settings.json, character for character.
export const SETTINGS_JSON = String.raw`{
  "hooks": {
    "SessionStart":     [{ "hooks": [{ "type": "command", "command": "sh \"$HOME/.claude/hooks/tmux-agent-state.sh\"" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "sh \"$HOME/.claude/hooks/tmux-agent-state.sh\"" }] }],
    "PreToolUse":       [{ "hooks": [{ "type": "command", "command": "sh \"$HOME/.claude/hooks/tmux-agent-state.sh\"", "async": true }] }],
    "PostToolUse":      [{ "hooks": [{ "type": "command", "command": "sh \"$HOME/.claude/hooks/tmux-agent-state.sh\"", "async": true }] }],
    "Notification":     [{ "hooks": [{ "type": "command", "command": "sh \"$HOME/.claude/hooks/tmux-agent-state.sh\"" }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "sh \"$HOME/.claude/hooks/tmux-agent-state.sh\"" }] }],
    "SubagentStop":     [{ "hooks": [{ "type": "command", "command": "sh \"$HOME/.claude/hooks/tmux-agent-state.sh\"", "async": true }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "sh \"$HOME/.claude/hooks/tmux-agent-state.sh\"" }] }]
  },
  "statusLine": {
    "type": "command",
    "command": "sh \"$HOME/.claude/hooks/claude-statusline.sh\"",
    "padding": 0,
    "refreshInterval": 30
  }
}`

export const EXTRAS = {
  title: 'Notifications, status bar, plugin',
  notifications: {
    title: 'Notifications',
    text: 'macOS asks once whether tagents may notify you. After that, a question, a permission prompt or a finished turn raises a banner, and a click opens that chat beside the list.',
    commands: 'tagents plugin add ~/.local/share/tagents/packages/notify\ntagents notify install',
  },
  statusBar: {
    title: 'Status bar',
    text: 'For the tmux status bar, a one-line tally of your chats by state:',
    command:
      "set -g status-right '#{?@tagents_counts,#{@tagents_counts},#(~/.local/bin/tagents --counts)}'",
  },
  plugin: {
    title: 'Claude Code plugin',
    text: 'Gives every chat the tagents skill, so it knows the exact commands and flags of tagents instead of guessing, and a knowledge MCP server that searches your markdown notes.',
    command: '/plugin install tagents --marketplace SkuratovichA/tagents',
  },
} as const
