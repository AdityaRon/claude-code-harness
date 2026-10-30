// What `hub.py panel` prints: the sections already sorted and named, so the
// pane only lays them out. Times are in quiet_hours.tz. `full` is a draft's
// whole message, which the expanded view shows in place of `text`.
export type Need = { key: string; ref: string; target: string; text: string; note: string; age: string; full?: string }
export type Going = {
  key: string
  post: string
  target: string
  ref: string
  text: string
  status: string
  warn: boolean
  full?: string
}
export type WithSession = { key: string; who: string; ref: string; text: string; since: string }
export type HeldDraft = { key: string; ref: string; target: string; text: string; reason: string; full?: string }
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
// The PRS section, from the last prs.json a scan wrote: one line a PR, what
// needs the user first, a count per repo, and the last five active days.
export type PrRow = { key: string; group: 'reviewing' | 'authored'; needs: boolean; line: string }
export type PrRepo = { repo: string; needs: number; total: number }
export type PrDay = { day: string; reviewed: number; approved: number; merged: number }
// `parked`: how many PRs `hub.py park` keeps off it.
export type Prs = { as_of: string; age: string; stale: boolean; repos: PrRepo[]; rows: PrRow[]; days: PrDay[]; parked?: number }
export type Panel = {
  state: string
  day: string
  prs?: Prs
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

// Compact (a glance: capped sections, rows cut at the edge) or expanded
// (every row, each message whole), and the sections opened past their cap
// while compact, by name. A look closes those; expanded stays.
export type View = { full: boolean; open: string[] }

declare module 'claude-code' {
  interface PluginState {
    'comms-panel': { snapshot: Shaped<Snapshot>; look: Shaped<Look>; view: Shaped<View> }
  }
}
