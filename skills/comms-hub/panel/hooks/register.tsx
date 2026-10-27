import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Held, Snapshot } from '../types'

// The comms session's held drafts and today's log beside the chat, so the user
// need not open each Slack thread. It reads files only: no model call, no
// tokens. `hub.py launch` loads it into the comms session alone.
const PANE = 'comms'
const TITLE = 'Comms'
const EMPTY: Snapshot = { stateDir: '', problem: '', held: [], day: '', log: [], readAt: 0 }
// Change the tag when Snapshot's fields change: it declines what an earlier
// version stored, which outlives a reload.
const snapshot = atom({ plugin: 'comms-panel', key: 'snapshot' } as const, EMPTY, { shape: 'snapshot-1' })

// The state dir as the scripts resolve it, from `hub.py config`, so the panel
// never repeats their config rules. Kept once found; a failure is asked again.
let known: string | undefined

async function stateDir($: EngineInterface): Promise<string> {
  if (known) return known
  const bin = `${$.plugin.root}/../bin`
  const py = await $.process.run(['bash', `${bin}/python.sh`], { timeoutMs: 10_000 })
  if (py.exitCode !== 0) throw new Error(py.stderr.trim() || 'python.sh found no interpreter')
  const cfg = await $.process.run([py.stdout.trim(), `${bin}/hub.py`, 'config'], { timeoutMs: 10_000 })
  const line = cfg.stdout.split('\n').find(l => l.startsWith('state: '))
  if (cfg.exitCode !== 0 || !line) throw new Error(cfg.stdout.trim() || cfg.stderr.trim() || 'hub.py config failed')
  known = line.slice('state: '.length)
  return known
}

// held/<peer>-<thread ts>.md: the draft's header down to `---`, then the message.
export function heldDraft(file: string, text: string): Held {
  const cut = text.search(/^---$/m)
  const head = cut < 0 ? text : text.slice(0, cut)
  const body = cut < 0 ? '' : text.slice(cut + 3)
  return {
    name: file.replace(/\.md$/, ''),
    to: /^to:\s*(.+)$/m.exec(head)?.[1]?.trim() ?? '',
    first: body.split('\n').map(l => l.trim()).find(Boolean) ?? '',
  }
}

async function snapshotOf($: EngineInterface): Promise<Snapshot> {
  const readAt = await $.clock.now()
  try {
    const dir = await stateDir($)
    const held: Held[] = []
    if (await $.fs.exists(`${dir}/held`)) {
      const files = (await $.fs.list(`${dir}/held`)).filter(f => f.kind === 'file' && f.name.endsWith('.md'))
      for (const f of files.sort((a, b) => a.name.localeCompare(b.name))) {
        held.push(heldDraft(f.name, await $.fs.read(`${dir}/held/${f.name}`)))
      }
    }
    // The newest day's log: the scripts name each file for the day in quiet_hours.tz.
    const days = (await $.fs.exists(`${dir}/log`)) ? (await $.fs.list(`${dir}/log`)).map(f => f.name) : []
    const newest = days.filter(n => /^\d{4}-\d{2}-\d{2}\.md$/.test(n)).sort().at(-1)
    const log = newest
      ? (await $.fs.read(`${dir}/log/${newest}`)).split('\n').filter(l => l.startsWith('- ')).map(l => l.slice(2))
      : []
    return { stateDir: dir, problem: '', held, day: newest?.slice(0, 10) ?? '', log, readAt }
  } catch (err) {
    return { ...EMPTY, problem: `comms-hub: ${err instanceof Error ? err.message : String(err)}`, readAt }
  }
}

async function refresh($: EngineInterface): Promise<void> {
  const next = await snapshotOf($)
  await update($, snapshot, () => next)
}

function clock(ms: number): string {
  return new Date(ms).toTimeString().slice(0, 5)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'comms', description: "Show the comms-hub held drafts and today's log" })
    void $.ui.open({ id: PANE, title: TITLE })
    void refresh($)

    return next(e)
  })

  on('command.run', { command: 'comms' }, async $ => {
    await $.ui.open({ id: PANE, title: TITLE })
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
    if (!s.stateDir) return <Text dimColor>Reading the comms-hub state.</Text>
    const held = s.held.flatMap(d => [
      <Text>{d.to ? `${d.name}  ${d.to}` : d.name}</Text>,
      ...(d.first ? [<Text dimColor>{`  ${d.first}`}</Text>] : []),
    ])
    const room = Math.max(1, (e.viewport?.rows ?? 24) - held.length - 5)
    const log = [...s.log].reverse().slice(0, room)

    return (
      <Box flexDirection="column">
        <Text weight="bold">{`Held (${s.held.length})`}</Text>
        {s.held.length === 0 ? <Text dimColor>none</Text> : held}
        <Text weight="bold">{s.day ? `${s.day} (${s.log.length})` : 'No log yet'}</Text>
        {log.map(line => <Text>{line}</Text>)}
        {s.log.length > log.length && <Text dimColor>{`${s.log.length - log.length} older`}</Text>}
        <Text dimColor>{`read ${clock(s.readAt)} from ${s.stateDir}`}</Text>
      </Box>
    )
  })
}
