import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Look, Panel, Snapshot } from '../types'

// The comms session's state beside the chat, for a glance after time away:
// what needs the user, what goes out and when, what is with other sessions,
// and what changed since they last looked. `hub.py panel` sorts and names it
// all (run.py --mutate tests it there); this lays it out, one line a row. It
// reads files only: no model call, no tokens. `hub.py launch` loads it into
// the comms session alone.
const PANE = 'comms'
const TITLE = 'Comms'
const EMPTY: Snapshot = { panel: null, problem: '', readAt: 0 }
// Change a tag when its fields change: it declines what an earlier version
// stored, which outlives a reload.
const snapshot = atom({ plugin: 'comms-panel', key: 'snapshot' } as const, EMPTY, { shape: 'snapshot-2' })
const look = atom({ plugin: 'comms-panel', key: 'look' } as const, { since: 0, last: 0 } as Look, { shape: 'look-1' })
// The most rows each section shows before "+k more"; the pane scrolls past that.
const ROWS = { needs: 8, going: 6, sessions: 6, held: 6, events: 12 }

// The interpreter the scripts use, found once; a failure is asked again.
let python: string | undefined

async function hub($: EngineInterface, args: string[]) {
  const bin = `${$.plugin.root}/../bin`
  if (!python) {
    const py = await $.process.run(['bash', `${bin}/python.sh`], { timeoutMs: 10_000 })
    if (py.exitCode !== 0) throw new Error(py.stderr.trim() || 'python.sh found no interpreter')
    python = py.stdout.trim()
  }
  return $.process.run([python, `${bin}/hub.py`, ...args], { timeoutMs: 20_000 })
}

async function snapshotOf($: EngineInterface): Promise<Snapshot> {
  const readAt = await $.clock.now()
  try {
    const out = await hub($, ['panel'])
    if (out.exitCode !== 0) throw new Error(out.stdout.trim() || out.stderr.trim() || 'hub.py panel failed')
    return { panel: JSON.parse(out.stdout) as Panel, problem: '', readAt }
  } catch (err) {
    return { ...EMPTY, problem: `comms-hub: ${err instanceof Error ? err.message : String(err)}`, readAt }
  }
}

async function refresh($: EngineInterface): Promise<void> {
  const next = await snapshotOf($)
  await update($, snapshot, () => next)
}

// Opening the pane or running /comms is a look: what was logged before the
// previous one loses its dot.
async function looked($: EngineInterface): Promise<void> {
  const at = await $.clock.now()
  await update($, look, l => ({ since: l.last, last: at }))
}

function words(...parts: string[]): string {
  return parts.filter(Boolean).join('  ')
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'comms', description: 'Show what needs you, what goes out, and what changed' })
    void $.ui.open({ id: PANE, title: TITLE })
    void looked($).then(() => refresh($))

    return next(e)
  })

  on('command.run', { command: 'comms' }, async $ => {
    await $.ui.open({ id: PANE, title: TITLE })
    await looked($)
    await refresh($)

    return { text: 'Comms pane opened.' }
  })

  // The comms session changes its state dir in its own turns, so a read as
  // each ends keeps the pane current without polling.
  on('turn.complete', async ($, e, next) => {
    const done = await next(e)
    if (e.agentId === undefined) await refresh($)

    return done
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    const s = await read($, snapshot)
    if (s.problem) return <Text color="error">{s.problem}</Text>
    const p = s.panel
    if (!p) return <Text dimColor>Reading the comms-hub state.</Text>
    const { since } = await read($, look)

    // A header, at most `max` rows, then how many more; one line each, cut at the edge.
    function section<T>(title: string, items: T[], max: number, row: (item: T) => unknown, always = false) {
      if (!items.length && !always) return []
      return [
        <Text weight="bold">{`${title} (${items.length})`}</Text>,
        ...(items.length ? items.slice(0, max).map(row) : [<Text dimColor>none</Text>]),
        ...(items.length > max ? [<Text dimColor>{`+${items.length - max} more`}</Text>] : []),
      ]
    }
    const fresh = p.events.filter(ev => Date.parse(ev.ts) > since).length

    return (
      <Box flexDirection="column">
        {section('NEEDS YOU', p.needs, ROWS.needs, n => (
          <Text color="warning" wrap="truncate-end">
            {`● ${words(n.ref, n.text, n.target, n.note)}  `}
            <Text dimColor>{n.age}</Text>
          </Text>
        ), true)}
        {section('GOING OUT', p.going, ROWS.going, g => (
          <Text wrap="truncate-end">
            <Text dimColor>{g.post}</Text>
            {`  ${words(g.target, g.ref, g.text)}  `}
            {g.warn ? <Text color="warning">{g.status}</Text> : <Text dimColor>{g.status}</Text>}
          </Text>
        ), true)}
        {section('WITH SESSIONS', p.sessions, ROWS.sessions, w => (
          <Text wrap="truncate-end">
            {`${words(w.who, w.ref, w.text)}  `}
            <Text dimColor>{`since ${w.since}`}</Text>
          </Text>
        ))}
        {/* Never a binding named h: JSX compiles to h(...), and one shadowing it threw on every held draft. */}
        {section('HELD', p.held, ROWS.held, d => (
          <Text wrap="truncate-end">
            {`${words(d.ref, d.text, d.target)}  `}
            <Text dimColor>{d.reason}</Text>
          </Text>
        ))}
        <Text weight="bold">{p.day ? `SINCE YOU LOOKED (${fresh} new) · ${p.day}` : 'SINCE YOU LOOKED'}</Text>
        {p.events.length === 0 && <Text dimColor>nothing logged yet</Text>}
        {p.events.slice(0, ROWS.events).map(ev => (
          <Text wrap="truncate-end">
            {Date.parse(ev.ts) > since ? '● ' : '  '}
            <Text dimColor>{ev.at}</Text>
            {`  ${words(ev.kind, ev.ref, ev.target, ev.text)}`}
            {ev.corrected ? <Text dimColor>  corrected</Text> : ''}
          </Text>
        ))}
        {p.events.length > ROWS.events && <Text dimColor>{`+${p.events.length - ROWS.events} more`}</Text>}
        <Text dimColor wrap="truncate-end">
          {`next tick ${p.next_tick} · last tick: ${p.last_tick} · read ${p.read}`}
        </Text>
      </Box>
    )
  })
}
