import { beforeEach, describe, expect, it, vi } from 'vitest'
import { nextTick, reactive } from 'vue'
const bridge = vi.hoisted(() => ({ handlers: [] as ((m: any) => void)[], sent: [] as any[], run: vi.fn() }))
vi.mock('../src/lib/connection', () => ({
  onMessage: (cb: (m: any) => void) => { bridge.handlers.push(cb); return () => {} },
  send: (m: any) => { bridge.sent.push(m)
    if (m.prepare) queueMicrotask(() => bridge.handlers.forEach(h => h({ t: 'actionVerified', id: m.id, result: { state: 'prepared', receipt: 'test-snapshot' } })))
    return true },
  runAction: bridge.run,
  state: reactive({ status: 'connected', appsLoaded: true, apps: [{ id: 'com.apple.finder', name: '访达' }], volume: { value: 0.5 } }),
}))
let lib: typeof import('../src/lib/assistant')
let conn: typeof import('../src/lib/connection')
const reply = (type: string, value: any) => {
  const req = bridge.sent.filter(m => m.t === (type === 'assistantPlan' ? 'assistantPlan' : 'verifyAction') && !m.prepare).at(-1)!
  bridge.handlers.forEach(h => h({ t: type, id: req.id, ...(type === 'assistantPlan' ? { plan: value } : { result: value }) }))
}
beforeEach(async () => {
  vi.resetModules(); bridge.handlers = []; bridge.sent = []; bridge.run.mockReset()
  bridge.run.mockResolvedValue({ ok: true })
  conn = await import('../src/lib/connection')
  conn.state.status = 'connected'
  lib = await import('../src/lib/assistant')
})
describe('assistant execution contract', () => {
  it('rejects the entire plan before any action when a later step is unsupported', async () => {
    const task = lib.perform('合成测试')
    reply('assistantPlan', { decision: 'execute', steps: [{ kind: 'app', id: 'com.apple.finder', op: 'open' }, { kind: 'shell', command: 'echo test' }] })
    await task
    expect(bridge.run).not.toHaveBeenCalled()
    expect(lib.assistant.phase).toBe('needs_check')
  })
  it('waits for a verified app before sending the exact literal text', async () => {
    const task = lib.perform('访达输入')
    reply('assistantPlan', { decision: 'execute', steps: [{ kind: 'app', id: 'com.apple.finder', op: 'open' }, { kind: 'text', text: "Don't close Chrome. 你好", enter: false }] })
    await vi.waitFor(() => expect(bridge.sent.some(m => m.t === 'verifyAction')).toBe(true))
    expect(bridge.run).toHaveBeenCalledTimes(1)
    reply('actionVerified', { state: 'verified' })
    await vi.waitFor(() => expect(bridge.run).toHaveBeenCalledTimes(2))
    await vi.waitFor(() => expect(bridge.sent.filter(m => m.t === 'verifyAction' && !m.prepare)).toHaveLength(2))
    reply('actionVerified', { state: 'verified' })
    await task
    expect(bridge.run.mock.calls[1]![0]).toEqual({ kind: 'text', text: "Don't close Chrome. 你好", enter: false })
    expect(lib.assistant.phase).toBe('done')
  })
  it('stops dependent typing if the app did not reach the intended state', async () => {
    const task = lib.perform('访达输入')
    reply('assistantPlan', { decision: 'execute', steps: [{ kind: 'app', id: 'com.apple.finder', op: 'open' }, { kind: 'text', text: '你好' }] })
    await vi.waitFor(() => expect(bridge.sent.some(m => m.t === 'verifyAction')).toBe(true))
    reply('actionVerified', { state: 'unverified', message: '目标未确认。' })
    await task
    expect(bridge.run).toHaveBeenCalledTimes(1)
    expect(lib.assistant.phase).toBe('needs_check')
  })
  it('does not continue or replay actions after a disconnect', async () => {
    let complete!: (v: any) => void
    bridge.run.mockImplementation(() => new Promise(r => { complete = r }))
    const task = lib.perform('访达输入')
    reply('assistantPlan', { decision: 'execute', steps: [{ kind: 'app', id: 'com.apple.finder', op: 'open' }, { kind: 'text', text: '你好' }] })
    await vi.waitFor(() => expect(bridge.run).toHaveBeenCalledTimes(1))
    conn.state.status = 'reconnecting'
    await nextTick()
    complete({ ok: true })
    await task
    conn.state.status = 'connected'
    await nextTick()
    expect(bridge.run).toHaveBeenCalledTimes(1)
    expect(lib.assistant.phase).toBe('stopped')
  })
  it('ignores a plan that returns after the user cancelled', async () => {
    const task = lib.perform('打开访达')
    lib.stopAssistant()
    reply('assistantPlan', { decision: 'execute', steps: [{ kind: 'app', id: 'com.apple.finder', op: 'open' }] })
    await task
    expect(bridge.run).not.toHaveBeenCalled()
  })
})


describe('one receipt for application execution and read-back', () => {
  function enable() { bridge.handlers.forEach(h => h({ t: 'aiStatus', status: { configured: true, checkedAppActions: true } })) }
  const app = { kind: 'app', id: 'com.apple.finder', op: 'open' }
  it('removes the extra network request while retaining verified completion', async () => {
    enable()
    bridge.run.mockResolvedValue({ ok: true, verification: { state: 'verified', message: '应用已切到前台。' } })
    const task = lib.perform('打开访达')
    reply('assistantPlan', { decision: 'execute', steps: [app] })
    await task
    expect(bridge.run).toHaveBeenCalledExactlyOnceWith(app, { verify: true })
    expect(bridge.sent.filter(m => m.t === 'verifyAction')).toHaveLength(0)
    expect(lib.assistant.steps[0]?.state).toBe('verified')
    expect(lib.assistant.recentApp).toBe(app.id)
  })
  it.each([undefined, { state: 'unverified' }])('stops dependent text if the inline read-back is absent or unverified: %s', async verification => {
    enable()
    bridge.run.mockResolvedValue({ ok: true, verification })
    const task = lib.perform('打开访达输入你好')
    reply('assistantPlan', { decision: 'execute', steps: [app, { kind: 'text', text: '你好' }] })
    await task
    expect(bridge.run).toHaveBeenCalledTimes(1)
    expect(bridge.sent.filter(m => m.t === 'verifyAction')).toHaveLength(0)
    expect(lib.assistant.phase).toBe('needs_check')
  })
  it('does not reuse a capability from a previous connection', () => {
    enable()
    expect(lib.assistant.checkedAppActions).toBe(true)
    bridge.handlers.forEach(h => h({ t: 'welcome' }))
    expect(lib.assistant.checkedAppActions).toBe(false)
  })
})
