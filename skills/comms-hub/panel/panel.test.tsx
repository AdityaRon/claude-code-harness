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

const STATE = '/home/me/.local/state/comms-hub'
const HELD = 'to: C0123 reply 1761040800.000100\nkind: reply\nclaims:\n- acme/app#12 merged | its PR\n---\n\nMerged after acme/app#11, thanks.\n'

// Each hook here stands for the engine: a call on `$` is answered `{ value }`.
function world(on, files: Record<string, string>, config = { exitCode: 0, stdout: `config: x\nstate: ${STATE}\n`, stderr: '' }) {
  on('command.register', () => ({ value: { command: 'comms' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('clock.now', () => ({ value: Date.UTC(2026, 9, 21, 17, 0) }))
  on('process.run', (_, e) =>
    ({ value: e.argv[0] === 'bash' ? { exitCode: 0, stdout: '/usr/bin/python3.12\n', stderr: '' } : config }))
  const names = (dir: string) => Object.keys(files).filter(p => p.startsWith(`${dir}/`)).map(p => p.slice(dir.length + 1))
  on('fs.exists', (_, e) => ({ value: names(e.path).length > 0 }))
  on('fs.list', (_, e) => ({ value: names(e.path).map(name => ({ name, kind: 'file', size: 1, mtimeMs: 0, isLink: false })) }))
  on('fs.read', (_, e) => ({ value: files[e.path] }))
}

async function texts($, surface = 'terminal') {
  const ui = await $.ui.mount({ ...PANE, surface })
  const out = (await ui.findAll({ type: 'Text' })).map(t => t.text)
  await ui.unmount()

  return out
}

test('the pane shows each held draft and the newest log, newest line first', async ($, on) => {
  const files = {
    [`${STATE}/held/app-session-1761040800.000100.md`]: HELD,
    [`${STATE}/log/2026-10-20.md`]: '- 09:00 yesterday\n',
    [`${STATE}/log/2026-10-21.md`]: '- 09:07 routed acme/app#12 to app-session\n- 09:12 sent 1761044400.000200 target=reply:1761040800.000100: bob asked when #12 merges\n',
  }
  world(on, files)
  await $.command.run({ command: 'comms', args: '' })

  for (const surface of ['terminal', 'desktop'] as const) {
    const out = await texts($, surface)
    expect(out).toContain('Held (1)')
    expect(out).toContain('app-session-1761040800.000100  C0123 reply 1761040800.000100')
    expect(out).toContain('  Merged after acme/app#11, thanks.')
    expect(out).toContain('2026-10-21 (2)')
    const sent = out.indexOf('09:12 sent 1761044400.000200 target=reply:1761040800.000100: bob asked when #12 merges')
    expect(sent).toBeGreaterThan(-1)
    expect(out.indexOf('09:07 routed acme/app#12 to app-session')).toBeGreaterThan(sent)
    expect(out).not.toContain('09:00 yesterday')
  }
})

test('a config the scripts refuse is said in the pane', async ($, on) => {
  world(on, {}, { exitCode: 2, stdout: 'config: no config at /home/me/.config/comms-hub/config.toml\n', stderr: '' })
  await $.command.run({ command: 'comms', args: '' })

  expect(await texts($)).toEqual(['comms-hub: config: no config at /home/me/.config/comms-hub/config.toml'])
})

test('the pane reads again when a turn ends', async ($, on) => {
  const files: Record<string, string> = { [`${STATE}/log/2026-10-21.md`]: '- 09:07 first\n' }
  world(on, files)
  on('turn.complete', () => ({ text: 'done' }))
  await $.command.run({ command: 'comms', args: '' })
  files[`${STATE}/log/2026-10-21.md`] += '- 09:30 held app-session 1761040800.000100: a fold-in is expected\n'
  await $.turn.complete({ reason: 'answer', answer: 'done', durationMs: 1, isAborted: false, turnId: 't1' })

  expect(await texts($)).toContain('09:30 held app-session 1761040800.000100: a fold-in is expected')
})
