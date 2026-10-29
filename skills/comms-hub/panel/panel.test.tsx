import { expect, test } from 'claude-code/testing'

const PANE = {
  plugin: 'comms-panel',
  component: 'Pane',
  requestId: 'comms',
  props: {
    title: 'Comms',
    isFocused: false,
    bodyColumns: 60,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 20 },
    view: {},
  },
} as const

const NOW = Date.UTC(2026, 9, 21, 17, 0)
// A line from before the JSONL log, which hub.py reads as prose.
const LONG = `an old free-text line ${'x'.repeat(280)}`

// What `hub.py panel` prints; its sorting and naming are tested in tests/test_panel_data.py.
const PANEL = {
  state: '/home/me/.local/state/comms-hub',
  day: 'Wed 21 Oct',
  needs: [{ key: 'held:a', ref: 'app #14', target: '#team-reviews', text: 'Carol, could you review #14?',
            note: 'needs your go', age: '2h' }],
  going: [
    { key: 'going:b', post: '08:30', target: 'Bob DM', ref: 'app #15', text: 'review ask', status: 'gated 09:50 ✓',
      warn: false },
    { key: 'going:c', post: '08:30', target: 'Bob DM', ref: 'app #16', text: 'a review ask not yet recorded',
      status: 'claim moved ⚠', warn: true },
  ],
  sessions: [{ key: 'row:1021.3', who: 'app-session', ref: 'app #16', text: 'conflicts', since: '09:20' }],
  held: [],
  events: [
    { key: 'row:1021.7', ts: '2026-10-21T16:46:00+00:00', at: '09:46', kind: 'sent', ref: '', target: '#team-reviews',
      text: 'reply to carol', corrected: false },
    { key: 'row:1021.4', ts: '2026-10-21T16:40:00+00:00', at: '09:30', kind: 'note', ref: '', target: '',
      text: 'the thread had 19 replies', corrected: true },
    { key: 'row:1021.md2', ts: '2026-10-21T16:00:00+00:00', at: '09:00', kind: 'note', ref: '', target: '',
      text: LONG, corrected: false },
  ],
  next_tick: '10:07',
  last_tick: '1 item',
  read: '10:00',
}

// Each hook here stands for the engine: a call on `$` is answered `{ value }`.
// `hub.py panel` answers with whatever `out.now` holds when it is asked.
function world(on, out = { now: { exitCode: 0, stdout: JSON.stringify(PANEL), stderr: '' } }) {
  on('command.register', () => ({ value: { command: 'comms' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('clock.now', () => ({ value: NOW }))
  on('process.run', (_, e) =>
    ({ value: e.argv[0] === 'bash' ? { exitCode: 0, stdout: '/usr/bin/python3.12\n', stderr: '' } : out.now }))
  return out
}

async function mounted($, surface = 'terminal') {
  return $.ui.mount({ ...PANE, surface })
}

async function texts($, surface = 'terminal') {
  const ui = await mounted($, surface)
  const out = (await ui.findAll({ type: 'Text' })).map(t => t.text)
  await ui.unmount()

  return out
}

test('what needs the user comes first, then what goes out, then what is with sessions', async ($, on) => {
  world(on)
  await $.command.run({ command: 'comms', args: '' })

  for (const surface of ['terminal', 'desktop'] as const) {
    const out = await texts($, surface)
    const at = (s: string) => out.findIndex(t => t.includes(s))
    expect(at('NEEDS YOU (1)')).toBe(0)
    expect(at('● app #14  Carol, could you review #14?  #team-reviews  needs your go')).toBe(1)
    expect(at('GOING OUT (2)')).toBeGreaterThan(1)
    expect(at('WITH SESSIONS (1)')).toBeGreaterThan(at('GOING OUT (2)'))
    expect(at('SINCE YOU LOOKED')).toBeGreaterThan(at('WITH SESSIONS (1)'))
    expect(at('HELD (')).toBe(-1)
    expect(out).toContain('next tick 10:07 · last tick: 1 item · read 10:00')
    const ui = await mounted($, surface)
    expect((await ui.find({ type: 'Text', text: /^claim moved ⚠$/ }))?.props.color).toBe('warning')
    await ui.unmount()
  }
})

test('a long line is one row cut at the pane edge', async ($, on) => {
  world(on)
  await $.command.run({ command: 'comms', args: '' })

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await mounted($, surface)
    const rows = await ui.findAll({ type: 'Text', text: LONG })
    expect(rows.length).toBe(1)
    expect(rows[0].props.wrap).toBe('truncate-end')
    for (const s of ['Carol, could you review #14?', 'a review ask not yet recorded', 'conflicts', 'reply to carol']) {
      expect((await ui.find({ type: 'Text', text: s }))?.props.wrap).toBe('truncate-end')
    }
    await ui.unmount()
  }
})

test('a corrected row is drawn once, and says so', async ($, on) => {
  world(on)
  await $.command.run({ command: 'comms', args: '' })

  const ui = await mounted($)
  expect((await ui.findAll({ type: 'Text', text: 'the thread had 19 replies' })).length).toBe(1)
  expect(await ui.findAll({ type: 'Text', text: /^\s*corrected$/ })).toHaveLength(1)
  await ui.unmount()
})

test('the unread dot clears after /comms', async ($, on) => {
  world(on)
  await $.command.run({ command: 'comms', args: '' })
  const first = await mounted($)
  expect((await first.find({ type: 'Text', text: 'reply to carol' }))?.text.startsWith('● ')).toBe(true)
  expect((await first.findAll({ type: 'Text', text: 'SINCE YOU LOOKED (3 new) · Wed 21 Oct' })).length).toBe(1)
  await first.unmount()

  await $.command.run({ command: 'comms', args: '' })
  const again = await mounted($)
  expect((await again.find({ type: 'Text', text: 'reply to carol' }))?.text.startsWith('● ')).toBe(false)
  expect((await again.findAll({ type: 'Text', text: 'SINCE YOU LOOKED (0 new) · Wed 21 Oct' })).length).toBe(1)
  await again.unmount()
})

test('a config the scripts refuse is said in the pane', async ($, on) => {
  world(on, { now: { exitCode: 2, stdout: 'config: no config at /home/me/.config/comms-hub/config.toml\n', stderr: '' } })
  await $.command.run({ command: 'comms', args: '' })

  expect(await texts($)).toEqual(['comms-hub: config: no config at /home/me/.config/comms-hub/config.toml'])
})

test('the pane reads again when a turn ends', async ($, on) => {
  const out = world(on)
  on('turn.complete', () => ({ text: 'done' }))
  await $.command.run({ command: 'comms', args: '' })
  const later = { ...PANEL, events: [{ key: 'row:1021.8', ts: '2026-10-21T16:58:00+00:00', at: '09:58', kind: 'held',
                                       ref: 'app #17', target: '', text: 'a fold-in is expected', corrected: false },
                                     ...PANEL.events] }
  out.now = { exitCode: 0, stdout: JSON.stringify(later), stderr: '' }
  await $.turn.complete({ reason: 'answer', answer: 'done', durationMs: 1, isAborted: false, turnId: 't1' })

  expect((await texts($)).some(t => t.includes('held  app #17  a fold-in is expected'))).toBe(true)
})
