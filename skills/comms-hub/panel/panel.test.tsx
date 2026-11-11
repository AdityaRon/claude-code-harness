import { expect, mock, test } from 'claude-code/testing'

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
  last_tick: '09:45, 1 event',
  read: '10:00',
}

// Fifteen events, three past the compact cap, and drafts with more than their first line.
const BUSY = {
  ...PANEL,
  events: [...PANEL.events, ...Array.from({ length: 12 }, (_, i) => ({
    key: `row:1021.${20 + i}`, ts: '2026-10-21T15:00:00+00:00', at: '08:00', kind: 'note', ref: '', target: '',
    text: `older note ${i}`, corrected: false }))],
  going: [{ ...PANEL.going[0], full: 'Bob, could you review #15?\n\nThe tables move first.' }],
  held: [{ key: 'held:d', ref: 'app #18', target: 'Bob DM', text: 'Merged.', reason: 'a fold-in is expected',
           full: 'Merged.\n\nIt ships in the next release.' }],
}

const json = (panel: object) => ({ exitCode: 0, stdout: JSON.stringify(panel), stderr: '' })

// Each hook here stands for the engine: a call on `$` is answered `{ value }`.
// `hub.py panel` answers with whatever `out.now` holds when it is asked.
// `opened` is what `$.ui.open` answers: a surface that docks no pane answers false.
// `roster` is what `$.session.surfaces()` answers: a phone attached is 'mobile' there.
function world(on, out = { now: json(PANEL) }, opened: object = { isPlaced: true }, roster: string[] = ['terminal']) {
  on('command.register', () => ({ value: { command: 'comms' } }))
  on('session.surfaces', () => ({ value: roster }))
  on('ui.open', () => ({ value: opened }))
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

// The person pressing a button the pane drew.
async function press($, key: string) {
  const ui = await mounted($)
  await ui.press({ key })
  await ui.unmount()
}

const EVENT_ROW = /^(● | {2})\d\d:\d\d {2}/

test('the summary counts each section, then what needs the user comes first', async ($, on) => {
  world(on)
  await $.command.run({ command: 'comms', args: '' })

  for (const surface of ['terminal', 'desktop'] as const) {
    const out = await texts($, surface)
    const at = (s: string) => out.findIndex(t => t.includes(s))
    expect(at('Comms · Wed 21 Oct')).toBe(0)
    expect(out).toContain('next tick 10:07 · last scan: 09:45, 1 event · read 10:00')
    // What is new sits with what needs the user: in the last heading alone it was off screen in a short pane.
    for (const c of ['1 need you', '3 PRs need you', '3 new', '2 going out', '1 with sessions', '0 held']) {
      expect(out).toContain(c)
    }
    expect(at('3 new')).toBeLessThan(at('2 going out'))
    const needs = at('NEEDS YOU · 1')
    expect(needs).toBeGreaterThan(at('0 held'))
    expect(out[needs + 1]).toBe('● app #14  #team-reviews  needs your go  2h')
    expect(out).toContain('    Carol, could you review #14?')
    expect(at('PRS · 5')).toBeGreaterThan(needs)
    expect(at('GOING OUT · 2')).toBeGreaterThan(at('PRS · 5'))
    expect(at('WITH SESSIONS · 1')).toBeGreaterThan(at('GOING OUT · 2'))
    // The five days are history: after what is live, before the events.
    expect(at('last 5 days')).toBeGreaterThan(at('WITH SESSIONS · 1'))
    expect(at('SINCE YOU LOOKED')).toBeGreaterThan(at('last 5 days'))
    expect(at('HELD')).toBe(-1)
    expect(at('nothing needs you')).toBe(-1)
  }
  expect(await border($)).toBe('warning')
  expect(await colorOf($, /^claim moved ⚠$/)).toBe('warning')
})

// Warning is what is on the user or wrong; success, what was checked.
test('GOING OUT puts the status before the message, and colours only what was checked or moved', async ($, on) => {
  const recheck = { key: 'going:d', post: 'Thu 08:30', target: '#platform', ref: 'app #19',
                    text: 'release note for the flag rollout', status: 're-check due', warn: false }
  world(on, { now: json({ ...PANEL, going: [...PANEL.going, recheck], last_tick: '09:45, 1 event · 2 missed since' }) })
  await $.command.run({ command: 'comms', args: '' })

  const out = await texts($)
  // Cut at the pane's edge, a row loses the end of its message, not its status.
  expect(out).toContain('08:30  Bob DM  app #16  claim moved ⚠  a review ask not yet recorded')
  expect(out).toContain('Thu 08:30  #platform  app #19  re-check due  release note for the flag rollout')
  expect(await colorOf($, /^gated 09:50 ✓$/)).toBe('success')
  expect(await colorOf($, /^claim moved ⚠$/)).toBe('warning')
  expect(await colorOf($, /^re-check due$/)).toBeUndefined()
  // The foot's one problem is not dim like the rest of it.
  expect(out).toContain('next tick 10:07 · last scan: 09:45, 1 event · 2 missed since · read 10:00')
  expect(await colorOf($, /^2 missed since$/)).toBe('warning')
  const ui = await mounted($)
  expect((await ui.find({ type: 'Text', text: /^next tick 10:07$/ }))?.props.dimColor).toBe(true)
  await ui.unmount()
})

// Claude Code deletes the tick's trigger after 7 days: "missed since" then only counted up.
test('an expired trigger leads the foot, in amber', async ($, on) => {
  world(on, { now: json({ ...PANEL, trigger: 'trigger expired 09:07' }) })
  await $.command.run({ command: 'comms', args: '' })

  expect(await texts($)).toContain('trigger expired 09:07 · next tick 10:07 · last scan: 09:45, 1 event · read 10:00')
  expect(await colorOf($, /^trigger expired 09:07$/)).toBe('warning')
})

// Ages and "stale" come from hub.py as it reads, so with no turn ending they froze.
test('the pane reads again each minute while it is drawn or a phone is here, and not while it waits undrawn', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  const out = { now: json(PANEL) }
  const panes = { placed: true }
  const roster = ['terminal']
  let reads = 0
  on('session.surfaces', () => ({ value: roster }))
  on('command.register', () => ({ value: { command: 'comms' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.panes', () => ({ value: [{ id: 'comms', title: 'Comms', isShown: panes.placed, isFocused: false,
                                    isPlaced: panes.placed }] }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.attach', (_, e) => ({ clientId: e.clientId }))
  on('process.run', (_, e) => {
    if (e.argv[0] === 'bash') return { value: { exitCode: 0, stdout: '/usr/bin/python3.12\n', stderr: '' } }
    reads += 1
    return { value: out.now }
  })
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await clock.advance(0)
  const first = reads

  out.now = json({ ...PANEL, prs: { ...PANEL.prs, age: '1m' } })
  await clock.advance(60_000)
  expect(reads).toBe(first + 1)
  expect((await texts($)).some(t => t.includes('as of 10:00 (1m ago)'))).toBe(true)

  panes.placed = false
  await clock.advance(60_000)
  expect(reads).toBe(first + 1)

  roster.push('mobile')
  await $.session.attach({ surface: 'mobile', clientId: 'phone-1' })
  const attached = reads
  await clock.advance(60_000)
  expect(reads).toBe(attached + 1)
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

test('before a scan writes the PR file, PRS says it is waiting', async ($, on) => {
  const none = { ...PANEL, prs: { as_of: '', age: '', stale: true, repos: [], rows: [], days: [] } }
  world(on, { now: json(none) })
  await $.command.run({ command: 'comms', args: '' })

  const out = await texts($)
  expect(out).toContain('PRS  waiting for a scan to write them')
  expect(out.some(t => t.startsWith('PRS ·'))).toBe(false)
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
  // Pending is CI's to finish, not the user's: plain, so warning keeps one meaning.
  expect(await colorOf($, /^ · CI pending$/)).toBeUndefined()
  expect(await colorOf($, /^ · CI red$/)).toBe('error')
  // An authored PR's decision shares the first part with its ref.
  expect(await colorOf($, /^app #40  approved, needs your merge$/)).toBe('warning')
  expect(await colorOf($, /^app #41  review required$/)).toBeUndefined()
  const ui = await mounted($)
  expect((await ui.find({ type: 'Text', text: /^  infra #9/ }))?.props.dimColor).toBe(true)
  expect((await ui.find({ type: 'Text', text: /^● app #31/ }))?.props.dimColor).toBe(false)
  await ui.unmount()
})

test('PRS says how many PRs are parked', async ($, on) => {
  world(on, { now: json({ ...PANEL, prs: { ...PANEL.prs, parked: 2 } }) })
  await $.command.run({ command: 'comms', args: '' })

  expect(await texts($)).toContain('PRS · 5  as of 10:00 (0m ago)  2 parked')
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

test('PRS shows ten rows, then a button for the rest', async ($, on) => {
  const rows = Array.from({ length: 12 }, (_, i) => ({ key: `pr:acme/app#${i}`, group: 'reviewing', needs: false,
                                                       line: `app #${i}  dana  not reviewed · CI green` }))
  world(on, { now: json({ ...PANEL, prs: { ...PANEL.prs, rows } }) })
  await $.command.run({ command: 'comms', args: '' })

  expect((await texts($)).filter(t => /^  app #\d+  dana/.test(t))).toHaveLength(10)
  const ui = await mounted($)
  expect((await ui.find({ type: 'Button', key: 'more:prs' }))?.text).toBe('+2 more')
  await ui.unmount()
})

test('expand shows every row and every message whole, and compact cuts them again', async ($, on) => {
  world(on, { now: json(BUSY) })
  await $.command.run({ command: 'comms', args: '' })

  const compact = await mounted($)
  expect((await compact.findAll({ type: 'Text', text: EVENT_ROW })).length).toBe(12)
  expect((await compact.find({ type: 'Button', key: 'more:events' }))?.text).toBe('+3 more')
  const toggle = await compact.find({ type: 'Button', key: 'view' })
  expect([toggle?.text, toggle?.props.hotkey]).toEqual(['expand', 'e'])
  expect((await compact.find({ type: 'Text', text: LONG }))?.props.wrap).toBe('truncate-end')
  expect(await compact.find({ type: 'Text', text: /next release/ })).toBeUndefined()
  expect((await compact.find({ type: 'Text', text: /^ {4}Carol, could/ }))?.props.dimColor).toBe(true)
  await compact.unmount()

  await press($, 'view')
  const full = await mounted($)
  expect((await full.findAll({ type: 'Text', text: EVENT_ROW })).length).toBe(15)
  expect(await full.find({ type: 'Button', key: 'more:events' })).toBeUndefined()
  expect((await full.find({ type: 'Button', key: 'view' }))?.text).toBe('compact')
  expect((await full.find({ type: 'Text', text: LONG }))?.props.wrap).toBe('wrap')
  expect((await full.find({ type: 'Text', text: /^ {4}Merged\./ }))?.text).toBe('    Merged.\n\nIt ships in the next release.')
  expect((await full.find({ type: 'Text', text: /^ {4}Bob, could/ }))?.text)
    .toBe('    Bob, could you review #15?\n\nThe tables move first.')
  // Expanded is for reading the message: at full strength, not dim.
  expect((await full.find({ type: 'Text', text: /^ {4}Merged\./ }))?.props.dimColor).toBe(false)
  expect((await full.find({ type: 'Text', text: /^ {4}Carol, could/ }))?.props.dimColor).toBe(false)
  // Expanded, the toggle at the top scrolls away: the way back is at the end too, with no second hotkey.
  const end = await full.find({ type: 'Button', key: 'view-end' })
  expect([end?.text, end?.props.hotkey]).toEqual(['compact', undefined])
  await full.unmount()

  await press($, 'view-end')
  const back = await mounted($)
  expect((await back.findAll({ type: 'Text', text: EVENT_ROW })).length).toBe(12)
  expect(await back.find({ type: 'Button', key: 'view-end' })).toBeUndefined()
  await back.unmount()

  await press($, 'view')
  await press($, 'view')
  expect((await texts($)).filter(t => EVENT_ROW.test(t))).toHaveLength(12)
})

test('a "+k more" button opens that section alone, and "fewer" in its place closes it', async ($, on) => {
  world(on, { now: json(BUSY) })
  await $.command.run({ command: 'comms', args: '' })

  await press($, 'more:events')
  const opened = await mounted($)
  expect((await opened.findAll({ type: 'Text', text: EVENT_ROW })).length).toBe(15)
  expect(await opened.find({ type: 'Button', key: 'more:events' })).toBeUndefined()
  expect((await opened.find({ type: 'Button', key: 'fewer:events' }))?.text).toBe('fewer')
  // The section alone: the pane stays compact, its rows still cut at the edge.
  expect((await opened.find({ type: 'Button', key: 'view' }))?.text).toBe('expand')
  expect((await opened.find({ type: 'Text', text: LONG }))?.props.wrap).toBe('truncate-end')
  await opened.unmount()

  await press($, 'fewer:events')
  const closed = await mounted($)
  expect((await closed.findAll({ type: 'Text', text: EVENT_ROW })).length).toBe(12)
  expect((await closed.find({ type: 'Button', key: 'more:events' }))?.text).toBe('+3 more')
  expect(await closed.find({ type: 'Button', key: 'fewer:events' })).toBeUndefined()
  await closed.unmount()
})

test('a look closes an opened section, and leaves expand as it was', async ($, on) => {
  world(on, { now: json(BUSY) })
  await $.command.run({ command: 'comms', args: '' })

  await press($, 'more:events')
  await $.command.run({ command: 'comms', args: '' })
  expect((await texts($)).filter(t => EVENT_ROW.test(t))).toHaveLength(12)

  await press($, 'view')
  await $.command.run({ command: 'comms', args: '' })
  const ui = await mounted($)
  expect((await ui.find({ type: 'Button', key: 'view' }))?.text).toBe('compact')
  expect((await ui.findAll({ type: 'Text', text: EVENT_ROW })).length).toBe(15)
  await ui.unmount()
})

test('the pane draws on the mobile surface, and /comms says it opened', async ($, on) => {
  world(on)
  const r = await $.command.run({ command: 'comms', args: '' })

  expect(r.text).toBe('Comms pane opened.')
  const out = await texts($, 'mobile')
  expect(out).toContain('NEEDS YOU · 1')
  expect(out).toContain('PRS · 5  as of 10:00 (0m ago)')
})

// The phone app docks no pane: /comms there once said "opened" and nothing drew.
// As the command's text, the list then rode every request after it.
test('/comms where no pane draws puts the state in the transcript, not in what the model is sent', async ($, on) => {
  const logs: string[] = []
  world(on, undefined, { isPlaced: false, reason: 'the attached surfaces place no panes: mobile' })
  on('ui.log', (_, e) => { if (e.to === 'transcript') logs.push(e.text); return { value: undefined } })
  const r = await $.command.run({ command: 'comms', args: '' })

  expect(r.text).toBe('Comms: the list is above (no pane here: the attached surfaces place no panes: mobile)')
  expect(logs).toEqual([
    'Comms · Wed 21 Oct: 1 need you · 3 PRs need you · 3 new · 2 going out · 1 with sessions · 0 held · next tick 10:07',
    '● app #14  #team-reviews  needs your go: Carol, could you review #14?',
    '● app #31  dana  commented@1111111 · new commits · CI green · approved by erin',
    '● app #32  dana  commented@2222222 · approvable · CI pending',
    '● app #40  approved, needs your merge · CI green',
    'GOING OUT · 2',
    '  08:30  Bob DM  app #15  gated 09:50 ✓  review ask',
    '  08:30  Bob DM  app #16  claim moved ⚠  a review ask not yet recorded',
    'WITH SESSIONS · 1',
    '  app-session  app #16  conflicts  since 09:20',
    'SINCE YOU LOOKED · 3 new',
    '  09:46  sent  #team-reviews  reply to carol',
    '  09:30  note  the thread had 19 replies',
    `  09:00  note  ${LONG}`,
  ])

  // A second look has nothing new since the first.
  logs.length = 0
  await $.command.run({ command: 'comms', args: '' })
  expect(logs.some(l => l.startsWith('SINCE YOU LOOKED'))).toBe(false)
  expect(logs).toContain('GOING OUT · 2')
})

test('/comms as text caps each section at the pane\'s compact rows', async ($, on) => {
  const out: string[] = []
  world(on, { now: json(BUSY) }, { isPlaced: false, reason: 'the attached surfaces place no panes: mobile' })
  on('ui.log', (_, e) => { out.push(e.text); return { value: undefined } })
  await $.command.run({ command: 'comms', args: '' })

  // The header counted a held draft and the text listed none.
  const held = out.indexOf('HELD · 1')
  expect(held).toBeGreaterThan(out.indexOf('WITH SESSIONS · 1'))
  expect(out[held + 1]).toBe('  app #18  Bob DM  a fold-in is expected: Merged.')
  const at = out.indexOf('SINCE YOU LOOKED · 15 new')
  expect(at).toBeGreaterThan(held)
  expect(out.slice(at + 1, at + 13).every(t => /^ {2}\d\d:\d\d {2}/.test(t))).toBe(true)
  expect(out[at + 13]).toBe('  +3 more')
})

test('a phone joining pins the counts on the status line, and its leaving clears them', async ($, on) => {
  const statuses: (string | undefined)[] = []
  const roster = ['terminal']
  world(on, undefined, undefined, roster)
  on('ui.status', (_, e) => { statuses.push(e.text); return { value: undefined } })
  on('session.attach', (_, e) => ({ clientId: e.clientId }))
  on('session.detach', (_, e) => ({ clientId: e.clientId }))
  await $.command.run({ command: 'comms', args: '' })
  expect(statuses).toEqual([])

  roster.push('mobile')
  await $.session.attach({ surface: 'mobile', clientId: 'mobile:1', viewport: { columns: 40, rows: 80, isFullscreen: false } })
  expect(statuses.at(-1))
    .toBe('Comms: 1 need you · 3 PRs need you · 3 new · 2 going out · 1 with sessions · 0 held · next tick 10:07 · /comms for the list')
  roster.pop()
  await $.session.detach({ surface: 'mobile', clientId: 'mobile:1', reason: 'detach' })
  expect(statuses.at(-1)).toBeUndefined()
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
  expect((await first.find({ type: 'Text', text: /^3 new$/ }))?.props.dimColor).toBeFalsy()
  await first.unmount()

  await $.command.run({ command: 'comms', args: '' })
  const again = await mounted($)
  expect((await again.find({ type: 'Text', text: 'reply to carol' }))?.text.startsWith('● ')).toBe(false)
  expect((await again.findAll({ type: 'Text', text: 'SINCE YOU LOOKED · 0 new' })).length).toBe(1)
  expect((await again.find({ type: 'Text', text: /^ · 0 new$/ }))?.props.color).toBeUndefined()
  expect((await again.find({ type: 'Text', text: /^0 new$/ }))?.props.dimColor).toBe(true)
  await again.unmount()
})

// With the pane docked, only session start and /comms were looks: the new count only grew.
test('seen takes every dot off at once, and shows only while something is new', async ($, on) => {
  const kept: unknown[] = []
  const w = live(on)
  on('store.set', (_, e) => { if (e.key === 'look') kept.push(e.value); return { value: undefined } })
  await start($, w)                                    // a look at 10:00
  await w.clock.advance(10 * 60_000)
  const ts = new Date(NOW + 5 * 60_000).toISOString()  // logged at 10:05, after that look
  w.out = json({ ...PANEL, events: [{ key: 'row:1021.9', ts, at: '10:05', kind: 'held', ref: 'app #17', target: '',
                                      text: 'a fold-in is expected', corrected: false }, ...PANEL.events] })
  await endTurn($)
  await w.clock.settle()
  const first = await mounted($)
  expect((await first.findAll({ type: 'Text', text: 'SINCE YOU LOOKED · 4 new' })).length).toBe(1)
  expect((await first.find({ type: 'Button', key: 'seen' }))?.props.hotkey).toBe('s')
  await first.unmount()

  await press($, 'seen')
  const after = await mounted($)
  expect((await after.findAll({ type: 'Text', text: 'SINCE YOU LOOKED · 0 new' })).length).toBe(1)
  expect((await after.find({ type: 'Text', text: /a fold-in is expected/ }))?.text.startsWith('● ')).toBe(false)
  expect(await after.find({ type: 'Button', key: 'seen' })).toBeUndefined()
  await after.unmount()
  expect(kept.at(-1)).toEqual({ since: NOW + 10 * 60_000, last: NOW + 10 * 60_000 })
})

// $.state lasts one session: after each relaunch every event of two log days was new again.
test('the last look outlives the session', async ($, on) => {
  const kept: unknown[] = []
  const w = live(on)
  const last = Date.parse('2026-10-21T16:45:00+00:00')
  on('store.get', (_, e) => ({ value: e.key === 'look' ? { since: 0, last } : undefined }))
  on('store.set', (_, e) => { if (e.key === 'look') kept.push(e.value); return { value: undefined } })
  await start($, w)
  expect((await texts($)).find(t => t.startsWith('SINCE YOU LOOKED'))).toBe('SINCE YOU LOOKED · 1 new')
  expect(kept).toEqual([{ since: last, last: NOW }])
})

test('a kept look of another shape is left alone', async ($, on) => {
  const w = live(on)
  mock.store(on, { look: 'from an older version' })
  await start($, w)
  expect((await texts($)).find(t => t.startsWith('SINCE YOU LOOKED'))).toBe('SINCE YOU LOOKED · 3 new')
})

test('a store that fails stops no read, and the dots fall back to the session\'s look', async ($, on) => {
  const w = live(on)
  on('store.get', () => { throw new Error('store.get failed') })
  on('store.set', () => { throw new Error('store.set failed') })
  await start($, w)
  expect(w.reads).toBe(1)
  expect((await texts($)).find(t => t.startsWith('SINCE YOU LOOKED'))).toBe('SINCE YOU LOOKED · 3 new')
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
    expect(out.findIndex(t => t.startsWith('last 5 days'))).toBeGreaterThan(at)
  }
})

test('a config the scripts refuse is said in the pane', async ($, on) => {
  world(on, { now: { exitCode: 2, stdout: 'config: no config at /home/me/.config/comms-hub/config.toml\n', stderr: '' } })
  await $.command.run({ command: 'comms', args: '' })

  expect(await texts($)).toEqual(['comms-hub: config: no config at /home/me/.config/comms-hub/config.toml'])
})

test('the pane reads again when a turn ends, and the turn\'s end does not wait for it', async ($, on) => {
  const w = live(on)
  await start($, w)
  const later = { ...PANEL, events: [{ key: 'row:1021.8', ts: '2026-10-21T16:58:00+00:00', at: '09:58', kind: 'held',
                                       ref: 'app #17', target: '', text: 'a fold-in is expected', corrected: false },
                                     ...PANEL.events] }
  w.out = json(later)
  w.slow = 20_000                                      // hub.py runs to its timeout
  let ended = false
  const ending = endTurn($).then(() => { ended = true })
  await w.clock.settle()
  expect(ended).toBe(true)
  await w.clock.advance(20_000)
  await ending
  expect((await texts($)).some(t => t.includes('held  app #17  a fold-in is expected'))).toBe(true)
})

// ---- when the pane reads, with a clock the test moves -------------------------

const aged = (age: string, read: string) => json({ ...PANEL, read, prs: { ...PANEL.prs, age } })
const TRACEBACK = 'Traceback (most recent call last):\n  File "hub.py", line 962, in going_out\n'
  + 'json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)\n'

// The engine beneath the mod: a pane placed or not, the roster of surfaces, and
// `hub.py panel` answering `w.out`. `slow` holds the next read that many clock
// milliseconds; `fails` names host calls that reject.
function live(on, { placed = true, surfaces = ['terminal'] } = {}) {
  const clock = mock.clock(on, { now: NOW })
  const w = { clock, placed, surfaces, out: aged('0m', '10:00') as object, reads: 0, slow: 0,
              statuses: [] as (string | undefined)[], fails: new Set<string>() }
  const or = (name: string, value: unknown) => {
    if (w.fails.has(name)) throw new Error(`${name} failed`)
    return { value }
  }
  on('command.register', () => ({ value: { command: 'comms' } }))
  on('ui.open', () => ({ value: w.placed ? { isPlaced: true } : { isPlaced: false, reason: 'narrow' } }))
  on('ui.panes', () => ({ value: [{ id: 'comms', title: 'Comms', isShown: w.placed, isFocused: false, isPlaced: w.placed }] }))
  on('ui.status', (_, e) => { w.statuses.push(e.text); return { value: undefined } })
  on('ui.log', () => ({ value: undefined }))
  on('session.surfaces', () => or('session.surfaces', w.surfaces))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.attach', (_, e) => ({ clientId: e.clientId }))
  on('session.detach', (_, e) => ({ clientId: e.clientId }))
  on('turn.complete', () => ({ text: 'done' }))
  on('process.run', async (_, e) => {
    if (e.argv[0] === 'bash') return { value: { exitCode: 0, stdout: '/usr/bin/python3.12\n', stderr: '' } }
    w.reads += 1
    const answer = w.out
    const hold = w.slow
    w.slow = 0
    if (hold) await clock.sleep(hold)
    return { value: answer }
  })
  return w
}

async function start($, w) {
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await w.clock.settle()
}

const prsLine = (out: string[]) => out.find(t => t.startsWith('PRS ·'))
const endTurn = $ => $.turn.complete({ reason: 'answer', answer: 'done', durationMs: 1, isAborted: false, turnId: 't1' })

// It waited a minute: only a phone attaching read, and only the minute's timer if it was drawn.
test('a pane drawn after waiting undrawn reads at once, not at the next minute', async ($, on) => {
  const w = live(on, { placed: false })
  await start($, w)
  for (let i = 0; i < 10; i++) await w.clock.advance(60_000)
  w.out = aged('10m', '10:10')
  w.placed = true
  await texts($)                                       // the surface asks the pane's ui.render
  await w.clock.advance(1_000)
  expect(prsLine(await texts($))).toBe('PRS · 5  as of 10:00 (10m ago)')
})

test('a draw asks for one read when the last is old, none when it is fresh, and never loops on a failing one', async ($, on) => {
  const w = live(on)
  await start($, w)
  const first = w.reads
  for (let i = 0; i < 5; i++) await texts($)
  await w.clock.advance(1_000)
  expect(w.reads).toBe(first)
  w.placed = false
  for (let i = 0; i < 10; i++) await w.clock.advance(60_000)
  w.out = { exitCode: 1, stdout: '', stderr: TRACEBACK }
  w.placed = true
  for (let i = 0; i < 5; i++) await texts($)            // five draws before the read lands
  await w.clock.advance(1_000)
  for (let i = 0; i < 5; i++) { await texts($); await w.clock.advance(1_000) }   // and five after it failed
  expect(w.reads - first).toBe(1)
})

test('a draw whose clock fails still draws', async ($, on) => {
  let failing = false
  on('session.surfaces', () => ({ value: ['terminal'] }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('clock.now', () => {
    if (failing) throw new Error('clock.now failed')
    return { value: NOW }
  })
  on('process.run', (_, e) =>
    ({ value: e.argv[0] === 'bash' ? { exitCode: 0, stdout: '/usr/bin/python3.12\n', stderr: '' } : json(PANEL) }))
  await $.command.run({ command: 'comms', args: '' })
  failing = true
  expect(prsLine(await texts($))).toBe('PRS · 5  as of 10:00 (0m ago)')
})

test('a desktop client joining is read for at once, as a phone is', async ($, on) => {
  const w = live(on)
  await start($, w)
  const before = w.reads
  await $.session.attach({ surface: 'desktop', clientId: 'desktop:1' })
  await w.clock.settle()
  expect(w.reads).toBe(before + 1)
})

test('a failed read keeps the last good panel, and says why in one line', async ($, on) => {
  const w = live(on)
  await start($, w)
  w.out = { exitCode: 1, stdout: '', stderr: TRACEBACK }
  await w.clock.advance(60_000)
  const out = await texts($)
  expect(out).toContain('NEEDS YOU · 1')
  expect(out[0]).toBe('read failed, showing 10:00: comms-hub: json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)')
  expect(out.some(t => t.includes('Traceback'))).toBe(false)
})

test('with two reads in flight, the pane ends on the one that started last', async ($, on) => {
  const w = live(on)
  await start($, w)
  const foot = async () => (await texts($)).find(t => t.startsWith('next tick'))?.split(' · ').at(-1)
  w.out = aged('1m', '10:01 before the turn ended')
  w.slow = 5_000                                       // the minute's read hangs for 5 s
  await w.clock.advance(60_000)
  w.out = aged('1m', '10:01 after the turn ended')
  await endTurn($)                                     // and the turn's own read answers at once
  await w.clock.settle()
  const between = await foot()
  await w.clock.advance(5_000)
  expect([between, await foot()]).toEqual(['read 10:01 after the turn ended', 'read 10:01 after the turn ended'])
})

test('session.start raised again (a reload, a worker respawn) is no look, and arms no second timer', async ($, on) => {
  const w = live(on)
  await start($, w)
  const heading = async () => (await texts($)).find(t => t.startsWith('SINCE YOU LOOKED'))
  expect(await heading()).toBe('SINCE YOU LOOKED · 3 new')
  await start($, w)
  expect(await heading()).toBe('SINCE YOU LOOKED · 3 new')
  const before = w.reads
  await w.clock.advance(60_000)
  expect(w.reads).toBe(before + 1)
})

test('an environment that never heard session.start arms the minute at the first turn end', async ($, on) => {
  const w = live(on)
  await endTurn($)
  await w.clock.settle()
  const before = w.reads
  await w.clock.advance(60_000)
  expect(w.reads).toBe(before + 1)
})

test('a phone on the roster with no attach heard (as after a reload) keeps its status line', async ($, on) => {
  const w = live(on, { placed: false, surfaces: ['terminal', 'mobile'] })
  await start($, w)
  w.statuses.length = 0
  await w.clock.advance(60_000)
  expect(w.statuses.at(-1)?.startsWith('Comms: 1 need you')).toBe(true)
})

test('a roster that fails to answer stops no read of a drawn pane', async ($, on) => {
  const w = live(on)
  await start($, w)
  w.fails.add('session.surfaces')
  const before = w.reads
  await w.clock.advance(60_000)
  expect(w.reads).toBe(before + 1)
})

test('a phone still listed when its detach is heard comes off the status line at the next minute', async ($, on) => {
  const w = live(on, { placed: false, surfaces: ['terminal', 'mobile'] })
  await start($, w)
  await $.session.detach({ surface: 'mobile', clientId: 'mobile:1', reason: 'detach' })
  expect(w.statuses.at(-1)?.startsWith('Comms: ')).toBe(true)
  w.surfaces = ['terminal']
  await w.clock.advance(60_000)
  expect(w.statuses.at(-1)).toBeUndefined()
})
