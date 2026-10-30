import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Look, Panel, Prs, Snapshot, View } from '../types'

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
const view = atom({ plugin: 'comms-panel', key: 'view' } as const, { full: false, open: [] } as View, { shape: 'view-2' })
// The most rows each section shows compact. A "+k more" button opens that
// section alone, and "fewer" in its place closes it; expand (e) shows every
// section's rows, each message whole.
const ROWS = { needs: 8, prs: 10, going: 6, sessions: 6, held: 6, events: 12 }

// The interpreter the scripts use, found once; a failure is asked again.
let python: string | undefined
// The phones attached now. The mobile app docks no pane, so while one is here
// the counts also ride the status line, which a remote surface draws.
const phones = new Set<string>()

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

async function refresh($: EngineInterface): Promise<Snapshot> {
  const next = await snapshotOf($)
  await update($, snapshot, () => next)
  if (phones.size) $.ui.status(statusLine(next))
  return next
}

// Opening the pane or running /comms is a look: what was logged before the
// previous one loses its dot, and a section opened at the last look closes.
// Expand is a preference, so it stays.
async function looked($: EngineInterface): Promise<void> {
  const at = await $.clock.now()
  await update($, look, l => ({ since: l.last, last: at }))
  await update($, view, v => ({ ...v, open: [] }))
}

function words(...parts: string[]): string {
  return parts.filter(Boolean).join('  ')
}

function counts(p: Panel): string {
  const prNeeds = (p.prs?.rows ?? []).filter(r => r.needs).length
  return [`${p.needs.length} need you`, `${prNeeds} PRs need you`, `${p.going.length} going out`,
          `${p.sessions.length} with sessions`, `${p.held.length} held`].join(' · ')
}

// One line for the status line while a phone is attached.
function statusLine(s: Snapshot): string {
  if (s.problem) return s.problem
  if (!s.panel) return 'Comms: reading the state'
  return `Comms: ${counts(s.panel)} · next tick ${s.panel.next_tick} · /comms for the list`
}

// A section of the text below: its title, then at most its compact rows.
function lines<T>(title: string, items: T[], max: number, line: (item: T) => string): string[] {
  if (!items.length) return []
  return [title, ...items.slice(0, max).map(item => `  ${line(item)}`),
          ...(items.length > max ? [`  +${items.length - max} more`] : [])]
}

// The panel as text, for /comms where no pane draws: the counts, what needs
// the user, the PRs that do, then what goes out, what is with sessions, and
// what was logged since the look before this one.
function summary(s: Snapshot, since: number): string {
  if (s.problem || !s.panel) return statusLine(s)
  const p = s.panel
  const fresh = p.events.filter(ev => Date.parse(ev.ts) > since)
  return [
    `Comms${p.day ? ` · ${p.day}` : ''}: ${counts(p)} · next tick ${p.next_tick}`,
    ...p.needs.map(n => `● ${words(n.ref, n.target, n.note)}: ${n.text}`),
    ...(p.prs?.rows ?? []).filter(r => r.needs).map(r => `● ${r.line}`),
    ...lines(`GOING OUT · ${p.going.length}`, p.going, ROWS.going,
             g => words(g.post, g.target, g.ref, g.text, g.status)),
    ...lines(`WITH SESSIONS · ${p.sessions.length}`, p.sessions, ROWS.sessions,
             w => words(w.who, w.ref, w.text, `since ${w.since}`)),
    ...lines(`SINCE YOU LOOKED · ${fresh.length} new`, fresh, ROWS.events,
             ev => words(ev.at, ev.kind, ev.ref, ev.target, ev.text)),
  ].join('\n')
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
    // Unasked, a pane waits undrawn on a narrow terminal or a surface that docks none: say why, off screen.
    void $.ui.open({ id: PANE, title: TITLE })
      .then(o => { if (!o.isPlaced) $.ui.log(`comms panel not drawn: ${o.reason}`, { to: 'debug' }) })
    void looked($).then(() => refresh($))

    return next(e)
  })

  on('command.run', { command: 'comms' }, async $ => {
    const opened = await $.ui.open({ id: PANE, title: TITLE })
    await looked($)
    const s = await refresh($)
    if (opened.isPlaced) return { text: 'Comms pane opened.' }

    // No pane here (the phone app docks none): the state as text instead, and why.
    const { since } = await read($, look)
    return { text: `${summary(s, since)}\n(no pane here: ${opened.reason})` }
  })

  // A phone joining: open the pane for it, and keep the counts on the status
  // line, in case its app draws no pane at all.
  on('session.attach', { surface: 'mobile' }, async ($, e, next) => {
    const done = await next(e)
    phones.add(e.clientId)
    await $.ui.open({ id: PANE, title: TITLE })
    await refresh($)

    return done
  })

  on('session.detach', { surface: 'mobile' }, async ($, e, next) => {
    const done = await next(e)
    phones.delete(e.clientId)
    if (!phones.size) $.ui.status(undefined)

    return done
  })

  // The comms session changes its state dir in its own turns, so a read as
  // each ends keeps the pane current without polling.
  on('turn.complete', async ($, e, next) => {
    const done = await next(e)
    if (e.agentId === undefined) await refresh($)

    return done
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Button, Text } = $.ui.resolve(e)
    const s = await read($, snapshot)
    if (s.problem) return <Text color="error">{s.problem}</Text>
    const p = s.panel
    if (!p) return <Text dimColor>Reading the comms-hub state.</Text>
    const { since } = await read($, look)
    const { full, open } = await read($, view)
    // Compact cuts a row at the pane's edge; expanded wraps it, so all of it reads.
    const cut = full ? 'wrap' : 'truncate-end'
    const fresh = p.events.filter(ev => Date.parse(ev.ts) > since).length
    // A hub.py from before the PRS section prints no `prs`.
    const prs: Prs = p.prs ?? { as_of: '', age: '', stale: true, repos: [], rows: [], days: [] }
    const prNeeds = prs.rows.filter(r => r.needs).length

    // A count in the summary: bold and coloured when there is something, dim at zero.
    function chip(n: number, label: string, color: string) {
      return n ? <Text><Text weight="bold" color={color}>{`${n}`}</Text>{` ${label}`}</Text>
               : <Text dimColor>{`0 ${label}`}</Text>
    }
    // A section's rows: all of them expanded or opened, else the first `max`.
    function shown<T>(name: string, items: T[], max: number): T[] {
      return full || open.includes(name) ? items : items.slice(0, max)
    }
    // What `shown` left out, as a button that opens that section alone. Once
    // open, "fewer" in the same place closes it, where the eye already is.
    function more(name: string, total: number, max: number) {
      if (full || total <= max) return []
      const isOpen = open.includes(name)
      return [<Button key={`${isOpen ? 'fewer' : 'more'}:${name}`} label={isOpen ? 'fewer' : `+${total - max} more`}
                      dimColor onPress={() => update($, view, v => ({
                        ...v, open: v.open.includes(name) ? v.open.filter(o => o !== name) : [...v.open, name] }))} />]
    }
    // A section only when it has rows: the summary already says which are empty.
    function section<T>(title: string, name: string, items: T[], max: number, row: (item: T) => unknown[],
                        color = 'claude') {
      if (!items.length) return []
      return [
        <Text weight="bold" color={color}>{`${title} · ${items.length}`}</Text>,
        ...shown(name, items, max).flatMap(row),
        ...more(name, items.length, max),
      ]
    }
    // What a row is about on its own line, so a long message never pushes it off the edge.
    function two(head: unknown, sub: string) {
      return [head, ...(sub ? [<Text dimColor wrap={cut}>{`    ${sub}`}</Text>] : [])]
    }
    // A draft's message: its first line compact, the whole of it expanded.
    const msg = (r: { text: string; full?: string }) => (full && r.full) || r.text
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
            <Button key="view" hotkey="e" plain label={full ? 'compact' : 'expand'}
                    onPress={() => update($, view, v => ({ ...v, full: !v.full }))} />
          </Box>
        </Box>

        {/* All clear only when no PR waits on the user either. */}
        {(p.needs.length > 0 || !prNeeds) && (
          <Box flexDirection="column">
            {p.needs.length === 0
              ? <Text color="success">nothing needs you ✓</Text>
              : section('NEEDS YOU', 'needs', p.needs, ROWS.needs, n => two(
                  <Text color="warning" wrap={cut}>
                    {`● ${words(n.ref, n.target, n.note)}  `}
                    <Text dimColor>{n.age}</Text>
                  </Text>, msg(n)), 'warning')}
          </Box>
        )}

        {/* No file yet (a first scan, or one that could not be read): said, never left blank. */}
        {p.prs && !prs.as_of && !prs.rows.length && (
          <Text wrap={cut}>
            <Text weight="bold" color="claude">PRS</Text>
            <Text dimColor>  waiting for a scan to write them</Text>
          </Text>
        )}
        {(prs.rows.length > 0 || prs.as_of) && (
          <Box flexDirection="column">
            <Text wrap={cut}>
              <Text weight="bold" color="claude">{`PRS · ${prs.rows.length}`}</Text>
              {prs.stale ? <Text color="warning">{`  stale, as of ${prs.as_of || 'never'}${prs.age ? ` (${prs.age} ago)` : ''}`}</Text>
                         : <Text dimColor>{`  as of ${prs.as_of} (${prs.age} ago)`}</Text>}
              {prs.parked ? <Text dimColor>{`  ${prs.parked} parked`}</Text> : ''}
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
            {shown('prs', prs.rows, ROWS.prs).map(r => (
              <Text wrap={cut} dimColor={!r.needs}>
                {r.needs ? <Text color="warning">● </Text> : '  '}
                {r.line.split(' · ').map((part, i) => (
                  <Text color={tone(part)}>{i ? ` · ${part}` : part}</Text>
                ))}
              </Text>
            ))}
            {more('prs', prs.rows.length, ROWS.prs)}
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
            {section('GOING OUT', 'going', p.going, ROWS.going, g => two(
              <Text wrap={cut}>
                <Text dimColor>{g.post}</Text>
                {`  ${words(g.target, g.ref, full ? '' : g.text)}  `}
                {g.warn ? <Text color="warning">{g.status}</Text> : <Text color="success">{g.status}</Text>}
              </Text>, full ? msg(g) : ''))}
          </Box>
        )}
        {p.sessions.length > 0 && (
          <Box flexDirection="column">
            {section('WITH SESSIONS', 'sessions', p.sessions, ROWS.sessions, w => two(
              <Text wrap={cut}>
                {`${words(w.who, w.ref)}  `}
                <Text dimColor>{`since ${w.since}`}</Text>
              </Text>, w.text))}
          </Box>
        )}
        {p.held.length > 0 && (
          <Box flexDirection="column">
            {section('HELD', 'held', p.held, ROWS.held, d => two(
              <Text wrap={cut}>
                {`${words(d.ref, d.target)}  `}
                <Text dimColor>{d.reason}</Text>
              </Text>, msg(d)))}
          </Box>
        )}

        <Box flexDirection="column">
          <Text weight="bold" color="claude">
            {'SINCE YOU LOOKED'}
            <Text color={fresh ? 'warning' : undefined}>{` · ${fresh} new`}</Text>
          </Text>
          {p.events.length === 0 && <Text dimColor>nothing logged yet</Text>}
          {shown('events', p.events, ROWS.events).map(ev => (
            <Text wrap={cut}>
              {Date.parse(ev.ts) > since ? <Text color="warning">● </Text> : '  '}
              <Text dimColor>{ev.at}</Text>
              {`  ${words(ev.kind, ev.ref, ev.target, ev.text)}`}
              {ev.corrected ? <Text dimColor>  corrected</Text> : ''}
            </Text>
          ))}
          {more('events', p.events.length, ROWS.events)}
        </Box>

        {/* Expanded, the pane outgrows its window and the toggle at the top scrolls away: a way back here too. */}
        {full && <Button key="view-end" plain label="compact" onPress={() => update($, view, v => ({ ...v, full: false }))} />}
      </Box>
    )
  })
}
