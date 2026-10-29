import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Look, Panel, Prs, Snapshot } from '../types'

// The comms session's state beside the chat, for a glance after time away:
// what needs the user, where their PRs stand, what goes out and when, what is
// with other sessions, and what changed since they last looked. `hub.py panel`
// sorts and names it all (run.py --mutate tests it there); this lays it out.
// It reads files only: no model call, no tokens. `hub.py launch` loads it into
// the comms session alone.
const PANE = 'comms'
const TITLE = 'Comms'
const EMPTY: Snapshot = { panel: null, problem: '', readAt: 0 }
// Change a tag when its fields change: it declines what an earlier version
// stored, which outlives a reload.
const snapshot = atom({ plugin: 'comms-panel', key: 'snapshot' } as const, EMPTY, { shape: 'snapshot-3' })
const look = atom({ plugin: 'comms-panel', key: 'look' } as const, { since: 0, last: 0 } as Look, { shape: 'look-1' })
// The most rows each section shows before "+k more"; the pane scrolls past that.
const ROWS = { needs: 8, prs: 10, going: 6, sessions: 6, held: 6, events: 12 }

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

const CI_COLOR: Record<string, string> = { green: 'success', red: 'error', pending: 'warning' }

// A part of a PR line (they are ` · ` apart): what waits on the user in
// warning, what is ready in success. An authored PR's decision shares the
// first part with its ref, hence the matches at the end.
function tone(part: string): string | undefined {
  if (/new commits|needs your (merge|read)$|changes requested$|unresolved$/.test(part)) return 'warning'
  if (part === 'approvable') return 'success'
  if (part === 'conflicts') return 'error'
  return part.startsWith('CI ') ? CI_COLOR[part.slice(3)] : undefined
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'comms', description: 'Show what needs you, your PRs, what goes out, and what changed' })
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
    const fresh = p.events.filter(ev => Date.parse(ev.ts) > since).length
    // A hub.py from before the PRS section prints no `prs`.
    const prs: Prs = p.prs ?? { as_of: '', age: '', stale: true, repos: [], rows: [], days: [] }
    const prNeeds = prs.rows.filter(r => r.needs).length

    // A count in the summary: bold and coloured when there is something, dim at zero.
    function chip(n: number, label: string, color: string) {
      return n ? <Text><Text weight="bold" color={color}>{`${n}`}</Text>{` ${label}`}</Text>
               : <Text dimColor>{`0 ${label}`}</Text>
    }
    // A section only when it has rows: the summary already says which are empty.
    function section<T>(title: string, items: T[], max: number, row: (item: T) => unknown[], color = 'claude') {
      if (!items.length) return []
      return [
        <Text weight="bold" color={color}>{`${title} · ${items.length}`}</Text>,
        ...items.slice(0, max).flatMap(row),
        ...(items.length > max ? [<Text dimColor>{`  +${items.length - max} more`}</Text>] : []),
      ]
    }
    // What a row is about on its own line, so a long message never pushes it off the edge.
    function two(head: unknown, sub: string) {
      return [head, ...(sub ? [<Text dimColor wrap="truncate-end">{`    ${sub}`}</Text>] : [])]
    }
    // The strip only once something happened in it; mono so the columns line up on a desktop too.
    const days = prs.days.some(d => d.reviewed || d.approved || d.merged) ? prs.days : []
    const col = (v: string | number) => `${v}`.padStart(7)

    return (
      <Box flexDirection="column" gap={1}>
        <Box flexDirection="column" borderStyle="round" borderColor={p.needs.length || prNeeds ? 'warning' : 'subtle'}
             paddingX={1}>
          <Box flexDirection="row" justifyContent="space-between" flexWrap="wrap" columnGap={2}>
            <Text weight="bold">{p.day ? `Comms · ${p.day}` : 'Comms'}</Text>
            <Text dimColor>{`next tick ${p.next_tick} · last tick: ${p.last_tick} · read ${p.read}`}</Text>
          </Box>
          <Box flexDirection="row" flexWrap="wrap" columnGap={2}>
            {chip(p.needs.length, 'need you', 'warning')}
            {chip(prNeeds, 'PRs need you', 'warning')}
            {chip(p.going.length, 'going out', 'suggestion')}
            {chip(p.sessions.length, 'with sessions', 'suggestion')}
            {chip(p.held.length, 'held', 'suggestion')}
          </Box>
        </Box>

        {/* All clear only when no PR waits on the user either. */}
        {(p.needs.length > 0 || !prNeeds) && (
          <Box flexDirection="column">
            {p.needs.length === 0
              ? <Text color="success">nothing needs you ✓</Text>
              : section('NEEDS YOU', p.needs, ROWS.needs, n => two(
                  <Text color="warning" wrap="truncate-end">
                    {`● ${words(n.ref, n.target, n.note)}  `}
                    <Text dimColor>{n.age}</Text>
                  </Text>, n.text), 'warning')}
          </Box>
        )}

        {(prs.rows.length > 0 || prs.as_of) && (
          <Box flexDirection="column">
            <Text wrap="truncate-end">
              <Text weight="bold" color="claude">{`PRS · ${prs.rows.length}`}</Text>
              {prs.stale ? <Text color="warning">{`  stale, as of ${prs.as_of || 'never'}${prs.age ? ` (${prs.age} ago)` : ''}`}</Text>
                         : <Text dimColor>{`  as of ${prs.as_of} (${prs.age} ago)`}</Text>}
            </Text>
            {prs.repos.length > 0 && (
              <Box flexDirection="row" flexWrap="wrap" columnGap={2}>
                {prs.repos.map(r => (
                  <Text>
                    <Text weight="bold">{r.repo}</Text>
                    {' '}
                    {r.needs ? <Text weight="bold" color="warning">{`${r.needs}`}</Text> : <Text dimColor>0</Text>}
                    <Text dimColor>{`/${r.total}`}</Text>
                  </Text>
                ))}
              </Box>
            )}
            {prs.rows.slice(0, ROWS.prs).map(r => (
              <Text wrap="truncate-end" dimColor={!r.needs}>
                {r.needs ? <Text color="warning">● </Text> : '  '}
                {r.line.split(' · ').map((part, i) => (
                  <Text color={tone(part)}>{i ? ` · ${part}` : part}</Text>
                ))}
              </Text>
            ))}
            {prs.rows.length > ROWS.prs && <Text dimColor>{`  +${prs.rows.length - ROWS.prs} more`}</Text>}
            {days.length > 0 && [
              <Text mono dimColor>{`${'last 5 days'.padEnd(11)}${days.map(d => col(d.day)).join('')}`}</Text>,
              ...(['reviewed', 'approved', 'merged'] as const).map(k => (
                <Text mono>{`${k.padEnd(11)}${days.map(d => col(d[k])).join('')}`}</Text>
              )),
            ]}
          </Box>
        )}

        {p.going.length > 0 && (
          <Box flexDirection="column">
            {section('GOING OUT', p.going, ROWS.going, g => [
              <Text wrap="truncate-end">
                <Text dimColor>{g.post}</Text>
                {`  ${words(g.target, g.ref, g.text)}  `}
                {g.warn ? <Text color="warning">{g.status}</Text> : <Text color="success">{g.status}</Text>}
              </Text>,
            ])}
          </Box>
        )}
        {p.sessions.length > 0 && (
          <Box flexDirection="column">
            {section('WITH SESSIONS', p.sessions, ROWS.sessions, w => two(
              <Text wrap="truncate-end">
                {`${words(w.who, w.ref)}  `}
                <Text dimColor>{`since ${w.since}`}</Text>
              </Text>, w.text))}
          </Box>
        )}
        {p.held.length > 0 && (
          <Box flexDirection="column">
            {section('HELD', p.held, ROWS.held, d => two(
              <Text wrap="truncate-end">
                {`${words(d.ref, d.target)}  `}
                <Text dimColor>{d.reason}</Text>
              </Text>, d.text))}
          </Box>
        )}

        <Box flexDirection="column">
          <Text weight="bold" color="claude">
            {'SINCE YOU LOOKED'}
            <Text color={fresh ? 'warning' : undefined}>{` · ${fresh} new`}</Text>
          </Text>
          {p.events.length === 0 && <Text dimColor>nothing logged yet</Text>}
          {p.events.slice(0, ROWS.events).map(ev => (
            <Text wrap="truncate-end">
              {Date.parse(ev.ts) > since ? <Text color="warning">● </Text> : '  '}
              <Text dimColor>{ev.at}</Text>
              {`  ${words(ev.kind, ev.ref, ev.target, ev.text)}`}
              {ev.corrected ? <Text dimColor>  corrected</Text> : ''}
            </Text>
          ))}
          {p.events.length > ROWS.events && <Text dimColor>{`  +${p.events.length - ROWS.events} more`}</Text>}
        </Box>
      </Box>
    )
  })
}
