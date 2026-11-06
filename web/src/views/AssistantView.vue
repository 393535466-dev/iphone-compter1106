<script setup lang="ts">
import { computed, onBeforeUnmount, onDeactivated, onMounted, ref, watch } from 'vue'
import { assistant, checkAI, perform, stopAssistant } from '@/lib/assistant'
import { onMessage, send, state } from '@/lib/connection'
import { describe } from '@/lib/actions'
import { labels } from '@/lib/connection'
import { startVoice, stopVoice, voice, voiceSupported } from '@/lib/voice'

const draft = ref(localStorage.getItem('cmdpalm-ai-draft') ?? '')
const language = ref(localStorage.getItem('cmdpalm-ai-language') ?? 'auto')
const finishing = ref(false)
const listening = ref(false)
const speechMs = ref(0)
let stoppedAt = 0
let manual = false
let finishTimer: ReturnType<typeof setTimeout> | undefined
const busy = computed(() => ['understanding', 'executing'].includes(assistant.phase))
const appNames = computed(() => new Map(state.apps.map(app => [app.id, app.name])))
function keepDraft() { localStorage.setItem('cmdpalm-ai-draft', draft.value); if (listening.value || finishing.value) manual = true }
function saveLanguage() { localStorage.setItem('cmdpalm-ai-language', language.value); send({ t: 'voicePrepare', locale: language.value }) }
function submit() { if (draft.value.trim()) void perform(draft.value, assistant.question ? { instruction: assistant.original, answer: draft.value } : undefined) }
watch(() => voice.error, error => { if (error) { cancelVoice(); assistant.message = error } })
watch(() => state.status, status => { if (status !== 'connected') cancelVoice() })
function visibility() { if (document.visibilityState === 'hidden') cancelVoice() }
document.addEventListener('visibilitychange', visibility)
function cancelVoice() {
  if ((listening.value || finishing.value) && !manual && voice.partial) {
    const phrase = voice.partial
    const space = /[A-Za-z0-9.!?]$/.test(draft.value) && /^[A-Za-z0-9]/.test(phrase) ? ' ' : ''
    draft.value += space + phrase
    localStorage.setItem('cmdpalm-ai-draft', draft.value)
    voice.partial = ''
  }
  listening.value = false; finishing.value = false; clearTimeout(finishTimer)
  void stopVoice(true)
}
const off = onMessage(m => {
  if (m.t !== 'voice' || !listening.value && !finishing.value) return
  if (m.state === 'error' || m.state === 'unavailable') {
    assistant.message = m.message ?? '识别没有完成，已保留文字，没有执行指令。'
    cancelVoice()
  } else if (m.state === 'stopped' && finishing.value) {
    clearTimeout(finishTimer)
    finishing.value = false
    speechMs.value = Math.round(performance.now() - stoppedAt)
    if (!manual && draft.value.trim()) submit()
    else assistant.message = manual ? '已保留你修改的文字，请确认后执行。' : '没有听到完整的话，请重试。'
  }
})
async function toggleVoice() {
  if (finishing.value) { cancelVoice(); assistant.message = '语音等待已取消，草稿已保留。'; return }
  if (listening.value) {
    listening.value = false; finishing.value = true; stoppedAt = performance.now()
    finishTimer = setTimeout(() => {
      cancelVoice(); assistant.message = '识别等待超时，草稿已保留，没有执行指令。'
    }, 8500)
    await stopVoice()
    return
  }
  if (busy.value || !voiceSupported()) return
  manual = false; draft.value = ''; speechMs.value = 0
  listening.value = true
  assistant.message = '正在听，点结束后直接执行。'
  await startVoice(phrase => {
    if (!listening.value && !finishing.value || manual) return
    const space = /[A-Za-z0-9.!?]$/.test(draft.value) && /^[A-Za-z0-9]/.test(phrase) ? ' ' : ''
    draft.value += space + phrase
    localStorage.setItem('cmdpalm-ai-draft', draft.value)
  }, language.value)
  if (!voice.active && !finishing.value) listening.value = false
}
onMounted(checkAI)
onDeactivated(cancelVoice)
onBeforeUnmount(() => { cancelVoice(); off(); document.removeEventListener('visibilitychange', visibility) })
</script>

<template>
  <section class="flex h-full flex-col overflow-y-auto p-4 gap-4">
    <header>
      <h1 class="text-xl font-semibold">让 Mac 帮你做事</h1>
      <p class="text-sm text-muted mt-1">控制电脑直接说动作；要写原文，请说“输入……”或切到键盘听写。</p>
    </header>
    <div v-if="assistant.question" class="text-sm rounded-xl border border-line p-3">
      正在补充：{{ assistant.question }}
      <button @click="assistant.question = ''; assistant.original = ''" class="ml-2 underline">改为新任务</button>
    </div>
    <div class="rounded-2xl border border-line p-4">
      <textarea v-model="draft" @input="keepDraft" rows="3" aria-label="你想让 Mac 做什么"
        placeholder="例如：打开微信，然后输入你好。文字填入 Mac 当前输入位置，不自动发送。"
        class="w-full bg-transparent outline-none resize-none text-base" />
      <p v-if="listening || finishing" class="text-sm text-muted mb-3" aria-live="polite">
        {{ finishing ? '正在确认末尾 · 再点语音可取消' : voice.partial || '正在听…' }}
      </p>
      <p v-if="voice.error" role="alert" class="text-sm text-bad mb-2">{{ voice.error }}</p>
      <div class="flex gap-2 items-center">
        <select v-model="language" @change="saveLanguage" aria-label="语音语言" class="rounded-lg p-2 text-sm" style="background:var(--surface)">
          <option value="zh-CN">中文</option><option value="auto">{{ assistant.speechProvider === "aliyun" ? "中英自动" : "跟随 Mac 语言" }}</option><option value="en-US">English</option>
        </select>
        <button @click="toggleVoice" :disabled="busy || state.status !== 'connected' || !voiceSupported()"
          :aria-label="listening ? '结束语音并执行' : finishing ? '取消语音等待' : '开始语音指令'"
          class="rounded-xl bg-accent text-white px-4 py-2">{{ listening ? '结束' : finishing ? '取消等待' : '语音' }}</button>
        <button @click="submit" :disabled="busy || listening || finishing || !draft.trim() || state.status !== 'connected'"
          class="rounded-xl bg-accent text-white px-4 py-2">执行</button>
      </div>
      <p class="mt-3 text-xs text-muted">{{ assistant.speechProvider === 'aliyun' ? '实时语音经 Mac 发送到阿里云识别' : '语音由 Mac 本机 Apple 识别' }} · 密钥只在 Mac</p>
    </div>
    <div class="flex flex-wrap gap-2">
      <button v-for="text in ['打开访达', '声音小点', '复制', '显示桌面']" :key="text" @click="draft = text; submit()"
        :disabled="busy" class="rounded-lg border border-line px-3 py-2 text-sm">{{ text }}</button>
    </div>
    <article v-if="assistant.message" class="rounded-2xl border border-line p-4" aria-live="polite">
      <div class="flex justify-between gap-2"><strong>{{ assistant.summary || assistant.instruction || '任务状态' }}</strong>
        <button v-if="busy" @click="stopAssistant" class="text-sm text-muted shrink-0">停止后续</button></div>
      <p class="mt-2 text-sm">{{ assistant.message }}</p>
      <ol class="mt-3 space-y-2 text-sm">
        <li v-for="(step, i) in assistant.steps" :key="i">
          {{ step.state === 'verified' ? '✓' : step.state === 'running' ? '…' : step.state === 'unverified' ? '请核对' : '○' }}
          {{ describe(step.action, labels, appNames) }}
          <span v-if="step.message" class="block text-xs text-muted">{{ step.message }}</span>
        </li>
      </ol>
      <p v-if="assistant.understandingMs || speechMs" class="text-xs text-muted mt-3">
        <span v-if="speechMs">语音收尾 {{ (speechMs / 1000).toFixed(1) }} 秒 · </span>
        理解 {{ (assistant.understandingMs / 1000).toFixed(1) }} 秒 · 执行与核对 {{ (assistant.executionMs / 1000).toFixed(1) }} 秒
      </p>
    </article>
  </section>
</template>
