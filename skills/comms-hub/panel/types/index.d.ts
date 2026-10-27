// A draft the comms session holds between ticks: held/<peer>-<thread ts>.md.
export type Held = { name: string; to: string; first: string }

// What the pane draws, as last read from the comms-hub state dir.
export type Snapshot = {
  stateDir: string
  problem: string
  held: Held[]
  day: string
  log: string[]
  readAt: number
}

declare module 'claude-code' {
  interface PluginState {
    'comms-panel': { snapshot: Shaped<Snapshot> }
  }
}
