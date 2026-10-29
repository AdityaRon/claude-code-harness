// What `hub.py panel` prints: the sections already sorted and named, so the
// pane only lays them out. Times are in quiet_hours.tz.
export type Need = { key: string; ref: string; target: string; text: string; note: string; age: string }
export type Going = { key: string; post: string; target: string; ref: string; text: string; status: string; warn: boolean }
export type WithSession = { key: string; who: string; ref: string; text: string; since: string }
export type HeldDraft = { key: string; ref: string; target: string; text: string; reason: string }
export type LogEvent = {
  key: string
  ts: string
  at: string
  kind: string
  ref: string
  target: string
  text: string
  corrected: boolean
}
export type Panel = {
  state: string
  day: string
  needs: Need[]
  going: Going[]
  sessions: WithSession[]
  held: HeldDraft[]
  events: LogEvent[]
  next_tick: string
  last_tick: string
  read: string
}

// What the pane draws, as last read.
export type Snapshot = { panel: Panel | null; problem: string; readAt: number }

// When the user last opened the pane or ran /comms (`last`), and the look
// before it (`since`): an event logged after `since` carries a dot.
export type Look = { since: number; last: number }

declare module 'claude-code' {
  interface PluginState {
    'comms-panel': { snapshot: Shaped<Snapshot>; look: Shaped<Look> }
  }
}
