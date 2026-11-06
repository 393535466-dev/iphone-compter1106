import { readFileSync } from 'node:fs'
import { runInNewContext } from 'node:vm'
import { describe, expect, it } from 'vitest'
const source = readFileSync('public/voice-worklet.js', 'utf8')
function processor(rate: number) {
  const messages: any[] = []
  let Constructor: any
  class Base { port = { onmessage: null as any, postMessage: (m: any) => messages.push(m) } }
  runInNewContext(source, { AudioWorkletProcessor: Base, sampleRate: rate, registerProcessor: (_: string, c: any) => { Constructor = c } })
  return { node: new Constructor({ processorOptions: { rate: 16000 } }), messages }
}
describe('PCM transport', () => {
  for (const rate of [44100, 48000]) {
    it('keeps one second of audio at ' + rate + ' Hz including the last partial frame', () => {
      const { node, messages } = processor(rate)
      for (let offset = 0; offset < rate; offset += 128) node.process([[new Float32Array(Math.min(128, rate - offset)).fill(0.25)]])
      node.port.onmessage({ data: { type: 'flush' } })
      const pcm = messages.filter(m => m.pcm).flatMap(m => Array.from(m.pcm) as number[])
      expect(Math.abs(pcm.length - 16000)).toBeLessThanOrEqual(1)
      expect(pcm.every(v => v > 8000 && v < 8300)).toBe(true)
      expect(messages.at(-1)).toEqual({ flushed: true })
      expect(messages.filter(m => m.pcm).every(m => m.pcm.length <= 320)).toBe(true)
    })
  }
  it('flushes a sub-frame utterance once instead of discarding its last words', () => {
    const { node, messages } = processor(48000)
    node.process([[new Float32Array(128).fill(0.3)]])
    expect(messages).toHaveLength(0)
    node.port.onmessage({ data: { type: 'flush' } })
    const count = messages.filter(m => m.pcm).length
    expect(count).toBe(1)
    expect(messages[0].pcm.length).toBeGreaterThan(0)
    node.port.onmessage({ data: { type: 'flush' } })
    expect(messages.filter(m => m.pcm)).toHaveLength(1)
  })
})
