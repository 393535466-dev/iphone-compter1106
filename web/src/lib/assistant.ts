import { reactive, watch } from 'vue'
import { onMessage, runAction, send, state } from './connection'
import { SYSTEM_ACTIONS, type Action } from './protocol'

export type Plan = { decision: 'execute' | 'clarify' | 'noop' | 'unsupported'; summary?: string; message?: string; steps: Action[]; understandingMs?: number; source?: string; model?: string }
type Verification = { state: 'verified' | 'unverified' | 'prepared'; message?: string; receipt?: string }
let counter = 0
let generation = 0
const pending = new Map<number, { resolve: (value: unknown) => void; timer: ReturnType<typeof setTimeout> }>()
export const assistant = reactive({
  phase: 'idle' as 'idle' | 'understanding' | 'executing' | 'done' | 'needs_check' | 'stopped',
  question: '', original: '', message: '', instruction: '', summary: '', model: '', understandingMs: 0, executionMs: 0,
  steps: [] as { action: Action; state: 'pending' | 'running' | 'verified' | 'unverified'; message: string }[],
  configured: false, speechProvider: 'apple', recentApp: '', recentAt: 0,
})
onMessage((m) => {
  if (m.t === 'welcome') send({ t: 'aiStatus' })
  if (m.t === 'aiStatus') {
    assistant.configured = m.status.configured
    assistant.speechProvider = m.status.speechProvider ?? 'apple'
    if (assistant.speechProvider === 'aliyun' && state.features.voice) send({ t: 'voicePrepare', locale: localStorage.getItem('cmdpalm-ai-language') ?? 'auto' })
    assistant.model = m.status.model ?? ''
  }
  if (m.t !== 'assistantPlan' && m.t !== 'actionVerified') return
  const request = pending.get(m.id)
  if (!request) return
  clearTimeout(request.timer)
  pending.delete(m.id)
  request.resolve(m.t === 'assistantPlan' ? m.plan : m.result)
})
function request(message: (id: number) => Parameters<typeof send>[0], timeout: number): Promise<unknown> {
  const id = ++counter
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new Error('等待结果超时，原话已保留。')) }, timeout)
    pending.set(id, { resolve, timer })
    if (!send(message(id))) { clearTimeout(timer); pending.delete(id); reject(new Error('Mac 未连接，未执行操作。')) }
  })
}
export function checkAI() { send({ t: 'aiStatus' }) }
export function validatePlan(value: unknown): Plan {
  const p = value as Plan
  if (!p || !['execute', 'clarify', 'noop', 'unsupported'].includes(p.decision)) throw new Error('任务计划无效。')
  if (p.decision !== 'execute') return { ...p, steps: [] }
  if (!Array.isArray(p.steps) || !p.steps.length || p.steps.length > 8) throw new Error('任务步骤无效。')
  const ids = new Set(state.apps.map(a => a.id))
  for (const a of p.steps) {
    if (!a || typeof a.kind !== 'string') throw new Error('动作无效。')
    if (a.kind === 'app') {
      if (!ids.has(a.id) || !['open', 'hide', 'quit'].includes(a.op ?? '')) throw new Error('目标应用未确认。')
    } else if (a.kind === 'text') {
      if (typeof a.text !== 'string' || !a.text || a.enter) throw new Error('输入正文无效或包含自动发送。')
    } else if (a.kind === 'url') {
      const u = new URL(a.url)
      if (!['http:', 'https:'].includes(u.protocol) || a.app && !ids.has(a.app)) throw new Error('网页或浏览器未确认。')
    } else if (a.kind === 'folder') {
      if (!['downloads', 'desktop', 'documents', 'home'].includes(a.name)) throw new Error('文件夹无效。')
    } else if (a.kind === 'system') {
      if (!SYSTEM_ACTIONS.includes(a.name) || ['forceQuit', 'sleep', 'sleepDisplay'].includes(a.name)) throw new Error('系统操作未支持。')
    } else if (a.kind === 'media') {
      if (!['volumeUp', 'volumeDown', 'mute', 'playPause', 'next', 'previous'].includes(a.key)) throw new Error('媒体操作无效。')
    } else if (a.kind === 'volume') {
      if (a.value !== undefined && (!Number.isFinite(a.value) || a.value < 0 || a.value > 1)) throw new Error('音量无效。')
      if (a.delta !== undefined && (!Number.isFinite(a.delta) || a.delta < -1 || a.delta > 1)) throw new Error('音量变化无效。')
      if (a.value === undefined && a.delta === undefined && typeof a.muted !== 'boolean') throw new Error('音量缺少参数。')
    } else throw new Error('当前基础版不执行脚本、自动发送消息或任意点击。')
  }
  return p
}
export function stopAssistant() {
  generation++
  assistant.phase = 'stopped'
  assistant.message = '已停止后续步骤。已生效的操作不会撤销。'
}
watch(() => state.status, status => {
  if (status !== 'connected' && ['understanding', 'executing'].includes(assistant.phase)) {
    stopAssistant()
    assistant.message = '连接中断，后续步骤已停止。请核对 Mac，恢复后不会自动重做。'
  }
})
async function verify(action: Action, receipt?: string): Promise<Verification> {
  try {
    return await request(id => ({ t: 'verifyAction', id, action, receipt }), 2000) as Verification
  } catch { return { state: 'unverified', message: '执行结果未确认，请核对 Mac。' } }
}
export async function perform(text: string, answers?: { instruction: string; answer: string }) {
  if (!text.trim() || state.status !== 'connected' || ['understanding', 'executing'].includes(assistant.phase)) return
  const run = ++generation
  assistant.phase = 'understanding'; assistant.summary = ''; assistant.instruction = text; assistant.message = '正在理解…'; assistant.steps = []
  assistant.understandingMs = 0; assistant.executionMs = 0
  try {
    if (!state.appsLoaded) {
      send({ t: 'apps' })
      for (let i = 0; i < 15 && !state.appsLoaded; i++) await new Promise(r => setTimeout(r, 50))
    }
    const started = performance.now()
    const context = { recentApp: Date.now() - assistant.recentAt < 600_000 ? assistant.recentApp : undefined, clarification: answers }
    const plan = validatePlan(await request(id => ({ t: 'assistantPlan', id, text: answers?.instruction ?? text, context }), 7500))
    if (run !== generation) return
    assistant.understandingMs = Math.round(performance.now() - started)
    assistant.summary = plan.summary ?? plan.message ?? ''
    assistant.question = plan.decision === 'clarify' && plan.source !== 'error' ? plan.message ?? '' : ''
    assistant.original = assistant.question ? answers?.instruction ?? text : ''
    if (plan.decision !== 'execute') {
      assistant.phase = 'done'; assistant.message = plan.message ?? plan.summary ?? '本次未操作电脑。'
      return
    }
    assistant.steps = plan.steps.map(action => ({ action, state: 'pending', message: '' }))
    assistant.phase = 'executing'; assistant.message = '正在操作 Mac…'
    send({ t: 'release' })
    const executing = performance.now()
    let uncertain = false
    for (const step of assistant.steps) {
      if (run !== generation) return
      step.state = 'running'
      const oldVolume = state.volume?.value
      // The Mac keeps the prior field contents locally; only an opaque receipt reaches the phone.
      let receipt: string | undefined
      if (step.action.kind === 'text') {
        try {
          const before = await request(id => ({ t: 'verifyAction', id, action: step.action, prepare: true }), 2000) as Verification
          receipt = before.receipt
        } catch { /* Typing still uses upstream behavior; inability to observe is not a pre-input gate. */ }
        if (run !== generation) return
      }
      const result = await runAction(step.action)
      if (run !== generation) return
      if (!result.ok) throw new Error(result.message ?? 'Mac 未确认操作结果。')
      let observedAction = step.action
      if (step.action.kind === 'volume' && step.action.delta !== undefined && oldVolume !== undefined) {
        observedAction = { kind: 'volume', value: Math.max(0, Math.min(1, oldVolume + step.action.delta)), muted: step.action.muted }
      }
      const resultState = await verify(observedAction, receipt)
      if (run !== generation) return
      step.state = resultState.state === 'verified' ? 'verified' : 'unverified'
      step.message = resultState.message ?? ''
      if (resultState.state === 'verified' && step.action.kind === 'app' && step.action.op === 'open') {
        assistant.recentApp = step.action.id; assistant.recentAt = Date.now()
      }
      if (resultState.state !== 'verified') {
        uncertain = true
        // A following text input depends on the right app and current focus.
        const next = assistant.steps[assistant.steps.indexOf(step) + 1]
        if (step.action.kind === 'app' || step.action.kind === 'text' || next?.action.kind === 'text') {
          assistant.message = step.message + ' 后续步骤尚未执行。'
          break
        }
      }
    }
    assistant.executionMs = Math.round(performance.now() - executing)
    assistant.phase = uncertain ? 'needs_check' : 'done'
    assistant.message = uncertain ? assistant.message === '正在操作 Mac…' ? '操作已发送，部分结果需要核对。' : assistant.message : '已核对完成。'
  } catch (e) {
    if (run !== generation) return
    assistant.phase = 'needs_check'
    assistant.message = e instanceof Error ? e.message : '未完成，原话已保留。'
  }
}
