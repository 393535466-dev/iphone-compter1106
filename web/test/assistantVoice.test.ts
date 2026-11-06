import { mount } from '@vue/test-utils'
import { reactive } from 'vue'
import { beforeEach, expect, it, vi } from 'vitest'
const mock = vi.hoisted(() => ({ handlers: [] as ((m: any) => void)[], final: null as ((s: string) => void) | null, perform: vi.fn() }))
vi.mock('../src/lib/connection', () => ({
  onMessage: (cb: (m: any) => void) => { mock.handlers.push(cb); return () => {} },
  state: reactive({ status: 'connected', apps: [] }), labels: new Map(),
}))
vi.mock('../src/lib/assistant', () => ({
  assistant: reactive({ phase: 'idle', question: '', original: '', speechProvider: 'aliyun', message: '', steps: [] }),
  checkAI: () => {}, stopAssistant: () => {}, perform: mock.perform,
}))
vi.mock('../src/lib/voice', () => ({
  voice: reactive({ active: false, partial: '', error: '' }), voiceSupported: () => true,
  startVoice: async (cb: (s: string) => void) => { mock.final = cb; const m = await import('../src/lib/voice'); m.voice.active = true },
  stopVoice: async () => { const m = await import('../src/lib/voice'); m.voice.active = false },
}))
beforeEach(() => { localStorage.clear(); mock.handlers = []; mock.perform.mockClear(); mock.final = null })
const emit = (state: string) => mock.handlers.forEach(h => h({ t: 'voice', state }))
it('executes once on a complete stopped event without a second transcription button', async () => {
  const View = (await import('../src/views/AssistantView.vue')).default
  const wrapper = mount(View)
  await wrapper.get('[aria-label="开始语音指令"]').trigger('click')
  mock.final!('打开访达')
  await wrapper.get('[aria-label="结束语音并执行"]').trigger('click')
  expect(mock.perform).not.toHaveBeenCalled()
  emit('stopped'); await wrapper.vm.$nextTick()
  emit('stopped')
  expect(mock.perform).toHaveBeenCalledTimes(1)
  expect(mock.perform.mock.calls[0]![0]).toBe('打开访达')
  wrapper.unmount()
})
it('keeps received text without executing when final recognition fails', async () => {
  const View = (await import('../src/views/AssistantView.vue')).default
  const wrapper = mount(View)
  await wrapper.get('[aria-label="开始语音指令"]').trigger('click')
  mock.final!('打开')
  await wrapper.get('[aria-label="结束语音并执行"]').trigger('click')
  emit('error'); emit('stopped'); await wrapper.vm.$nextTick()
  expect(mock.perform).not.toHaveBeenCalled()
  expect(wrapper.get('textarea').element.value).toBe('打开')
  wrapper.unmount()
})
