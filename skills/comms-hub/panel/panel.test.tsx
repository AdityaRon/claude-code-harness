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

const day = (d: string, reviewed: number, approved: number, merged: number) => ({ day: d, reviewed, approved, merged })

// What `hub.py panel` prints; its sorting and naming are tested in tests/test_panel_data.py.
const PANEL = {
  state: '/home/me/.local/state/comms-hub',
  day: 'Wed 21 Oct',
  prs: {
    as_of: '10:00',
    age: '0m',
    stale: false,
    repos: [{ repo: 'app', needs: 3, total: 4 }, { repo: 'infra', needs: 0, total: 1 }],
    rows: [
      { key: 'pr:acme/app#31', group: 'reviewing', needs: true,
        line: 'app #31  dana  commented@1111111 · new commits · CI green · approved by erin' },
      { key: 'pr:acme/app#32', group: 'reviewing', needs: true, line: 'app #32  dana  commented@2222222 · approvable · CI pending' },
      { key: 'pr:acme/app#40', group: 'authored', needs: true, line: 'app #40  approved, needs your merge · CI green' },
      { key: 'pr:acme/app#41', group: 'authored', needs: false, line: 'app #41  review required · CI pending' },
      { key: 'pr:acme/infra#9', group: 'reviewing', needs: false, line: 'infra #9  dana  commented@2222222 · CI red' },
    ],
    days: [day('Thu 15', 0, 0, 0), day('Fri 16', 1, 0, 1), day('Mon 19', 0, 0, 0), day('Tue 20', 3, 1, 0),
           day('Wed 21', 2, 1, 12)],
  },
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

const json = (panel: object) => ({ exitCode: 0, stdout: JSON.stringify(panel), stderr: '' })

// Each hook here stands for the engine: a call on `$` is answered `{ value }`.
// `hub.py panel` answers with whatever `out.now` holds when it is asked.
function world(on, out = { now: json(PANEL) }) {
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

// The summary's border: warning while anything waits on the user.
async function border($) {
  const ui = await mounted($)
  const box = (await ui.findAll({ type: 'Box' })).find(b => b.props.borderStyle === 'round')
  await ui.unmount()

  return box?.props.borderColor
}

async function colorOf($, text: string | RegExp) {
  const ui = await mounted($)
  const found = await ui.find({ type: 'Text', text })
  await ui.unmount()

  return found?.props.color
}

test('the summary counts each section, then what needs the user comes first', async ($, on) => {
  world(on)
  await $.command.run({ command: 'comms', args: '' })

  for (const surface of ['terminal', 'desktop'] as const) {
    const out = await texts($, surface)
    const at = (s: string) => out.findIndex(t => t.includes(s))
    expect(at('Comms · Wed 21 Oct')).toBe(0)
    expect(out).toContain('next tick 10:07 · last tick: 1 item · read 10:00')
    for (const c of ['1 need you', '3 PRs need you', '2 going out', '1 with sessions', '0 held']) expect(out).toContain(c)
    const needs = at('NEEDS YOU · 1')
    expect(needs).toBeGreaterThan(at('0 held'))
    expect(out[needs + 1]).toBe('● app #14  #team-reviews  needs your go  2h')
    expect(out).toContain('    Carol, could you review #14?')
    expect(at('PRS · 5')).toBeGreaterThan(needs)
    expect(at('GOING OUT · 2')).toBeGreaterThan(at('PRS · 5'))
    expect(at('WITH SESSIONS · 1')).toBeGreaterThan(at('GOING OUT · 2'))
    expect(at('SINCE YOU LOOKED')).toBeGreaterThan(at('WITH SESSIONS · 1'))
    expect(at('HELD')).toBe(-1)
    expect(at('nothing needs you')).toBe(-1)
  }
  expect(await border($)).toBe('warning')
  expect(await colorOf($, /^claim moved ⚠$/)).toBe('warning')
})

test('with nothing waiting, the summary is quiet and says so', async ($, on) => {
  const quiet = { ...PANEL, needs: [], prs: { ...PANEL.prs, rows: PANEL.prs.rows.map(r => ({ ...r, needs: false })) } }
  world(on, { now: json(quiet) })
  await $.command.run({ command: 'comms', args: '' })

  const out = await texts($)
  expect(out).toContain('0 need you')
  expect(out).toContain('0 PRs need you')
  expect(out.some(t => t.startsWith('NEEDS YOU'))).toBe(false)
  expect(await colorOf($, 'nothing needs you ✓')).toBe('success')
  expect(await border($)).toBe('subtle')
})

test('a PR that needs the user lights the summary when nothing else waits', async ($, on) => {
  world(on, { now: json({ ...PANEL, needs: [] }) })
  await $.command.run({ command: 'comms', args: '' })

  const out = await texts($)
  expect(out).toContain('0 need you')
  expect(out).toContain('3 PRs need you')
  expect(out.some(t => t.includes('nothing needs you'))).toBe(false)
  expect(await border($)).toBe('warning')
})

test('a hub.py from before the PRS section draws the rest as it did', async ($, on) => {
  const { prs, ...older } = PANEL
  world(on, { now: json(older) })
  await $.command.run({ command: 'comms', args: '' })

  const out = await texts($)
  expect(out.some(t => t.startsWith('PRS'))).toBe(false)
  expect(out).toContain('0 PRs need you')
  expect(out).toContain('GOING OUT · 2')
})

test('PRS counts each repo, marks what needs the user, and colours what waits and what is ready', async ($, on) => {
  world(on)
  await $.command.run({ command: 'comms', args: '' })

  for (const surface of ['terminal', 'desktop'] as const) {
    const out = await texts($, surface)
    expect(out).toContain('PRS · 5  as of 10:00 (0m ago)')
    expect(out).toContain('app 3/4')
    expect(out).toContain('infra 0/1')
    expect(out).toContain('● app #31  dana  commented@1111111 · new commits · CI green · approved by erin')
    expect(out).toContain('  infra #9  dana  commented@2222222 · CI red')
  }
  expect(await colorOf($, /^ · new commits$/)).toBe('warning')
  expect(await colorOf($, /^ · approvable$/)).toBe('success')
  expect(await colorOf($, /^ · CI pending$/)).toBe('warning')
  expect(await colorOf($, /^ · CI red$/)).toBe('error')
  // An authored PR's decision shares the first part with its ref.
  expect(await colorOf($, /^app #40  approved, needs your merge$/)).toBe('warning')
  expect(await colorOf($, /^app #41  review required$/)).toBeUndefined()
  const ui = await mounted($)
  expect((await ui.find({ type: 'Text', text: /^  infra #9/ }))?.props.dimColor).toBe(true)
  expect((await ui.find({ type: 'Text', text: /^● app #31/ }))?.props.dimColor).toBe(false)
  await ui.unmount()
})

test('the last five days line up in columns', async ($, on) => {
  world(on)
  await $.command.run({ command: 'comms', args: '' })

  const ui = await mounted($, 'desktop')
  const rows = await ui.findAll({ type: 'Text', text: /^(last 5 days|reviewed|approved|merged) / })
  expect(rows.map(r => r.text)).toEqual([
    'last 5 days Thu 15 Fri 16 Mon 19 Tue 20 Wed 21',
    'reviewed         0      1      0      3      2',
    'approved         0      0      0      1      1',
    'merged           0      1      0      0     12',
  ])
  expect(rows.every(r => r.props.mono === true)).toBe(true)
  await ui.unmount()
})

test('a stale PR file says when it is from, and a quiet week draws no table', async ($, on) => {
  const stale = { ...PANEL, prs: { ...PANEL.prs, stale: true, as_of: '08:30', age: '1h',
                                   days: PANEL.prs.days.map(d => day(d.day, 0, 0, 0)) } }
  world(on, { now: json(stale) })
  await $.command.run({ command: 'comms', args: '' })

  expect(await colorOf($, /^  stale, as of 08:30 \(1h ago\)$/)).toBe('warning')
  expect((await texts($)).some(t => t.startsWith('last 5 days'))).toBe(false)
})

test('PRS shows ten rows, then a count of the rest', async ($, on) => {
  const rows = Array.from({ length: 12 }, (_, i) => ({ key: `pr:acme/app#${i}`, group: 'reviewing', needs: false,
                                                       line: `app #${i}  dana  not reviewed · CI green` }))
  world(on, { now: json({ ...PANEL, prs: { ...PANEL.prs, rows } }) })
  await $.command.run({ command: 'comms', args: '' })

  const out = await texts($)
  expect(out.filter(t => /^  app #\d+  dana/.test(t))).toHaveLength(10)
  expect(out).toContain('  +2 more')
})

test('a long line is one row cut at the pane edge', async ($, on) => {
  world(on)
  await $.command.run({ command: 'comms', args: '' })

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await mounted($, surface)
    const rows = await ui.findAll({ type: 'Text', text: LONG })
    expect(rows.length).toBe(1)
    expect(rows[0].props.wrap).toBe('truncate-end')
    for (const s of ['Carol, could you review #14?', 'a review ask not yet recorded', 'conflicts', 'reply to carol',
                     'app #31  dana']) {
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
  expect((await first.findAll({ type: 'Text', text: 'SINCE YOU LOOKED · 3 new' })).length).toBe(1)
  expect((await first.find({ type: 'Text', text: /^ · 3 new$/ }))?.props.color).toBe('warning')
  await first.unmount()

  await $.command.run({ command: 'comms', args: '' })
  const again = await mounted($)
  expect((await again.find({ type: 'Text', text: 'reply to carol' }))?.text.startsWith('● ')).toBe(false)
  expect((await again.findAll({ type: 'Text', text: 'SINCE YOU LOOKED · 0 new' })).length).toBe(1)
  expect((await again.find({ type: 'Text', text: /^ · 0 new$/ }))?.props.color).toBeUndefined()
  await again.unmount()
})

// v1.1.9 named the HELD row's parameter `h`, which shadowed the JSX factory:
// every render with a held draft threw "h is not a function" and drew nothing.
test('a held draft draws its row', async ($, on) => {
  const held = { ...PANEL, held: [{ key: 'held:d', ref: 'app #18', target: 'Bob DM', text: 'Merged.',
                                    reason: 'a fold-in from app-session is expected' }] }
  world(on, { now: json(held) })
  await $.command.run({ command: 'comms', args: '' })

  for (const surface of ['terminal', 'desktop'] as const) {
    const out = await texts($, surface)
    expect(out).toContain('1 held')
    const at = out.indexOf('HELD · 1')
    expect(at).toBeGreaterThan(0)
    expect(out[at + 1]).toBe('app #18  Bob DM  a fold-in from app-session is expected')
    expect(out).toContain('    Merged.')
  }
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
  out.now = json(later)
  await $.turn.complete({ reason: 'answer', answer: 'done', durationMs: 1, isAborted: false, turnId: 't1' })

  expect((await texts($)).some(t => t.includes('held  app #17  a fold-in is expected'))).toBe(true)
})
