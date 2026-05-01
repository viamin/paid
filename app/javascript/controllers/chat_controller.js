import { Controller } from "@hotwired/stimulus"
import consumer from "../channels/consumer"

export default class extends Controller {
  static targets = ["container", "messages", "input", "status", "typingIndicator", "tokenUsage"]
  static values = { sessionId: Number }

  connect() {
    this.autoScroll = true
    this.streaming = false
    this.currentStreamId = null

    this.subscription = consumer.subscriptions.create(
      { channel: "ChatChannel", session_id: this.sessionIdValue },
      {
        connected: () => this.setStatus("Connected"),
        disconnected: () => this.setStatus("Disconnected"),
        rejected: () => this.setStatus("Subscription rejected"),
        received: (data) => this.handleEvent(data)
      }
    )
  }

  disconnect() {
    this.subscription?.unsubscribe()
  }

  sendMessage(event) {
    const content = event.detail.content?.trim()
    if (!content || this.streaming) return

    this.appendMessage({ role: "user", content })
    this.setBusy(true)
    this.subscription.perform("send_message", { content })
    this.scrollToBottom()
  }

  submitForm(event) {
    event.target.form?.requestSubmit()
  }

  submitTitleOnBlur(event) {
    const input = event.target
    if (input.name?.endsWith("[title]")) {
      input.form?.requestSubmit()
    }
  }

  handleScroll() {
    const threshold = 48
    const distanceFromBottom = this.containerTarget.scrollHeight - this.containerTarget.scrollTop - this.containerTarget.clientHeight
    this.autoScroll = distanceFromBottom <= threshold
  }

  handleEvent(data) {
    switch (data.type) {
    case "message_start":
      this.handleMessageStart(data)
      break
    case "message_chunk":
      this.handleMessageChunk(data)
      break
    case "message_complete":
      this.handleMessageComplete(data)
      break
    case "error":
      this.handleError(data)
      break
    }
  }

  handleMessageStart(data) {
    this.currentStreamId = data.message_id
    this.streaming = true
    this.setStatus(`Streaming ${data.model || "assistant"} response…`)
    this.toggleTyping(true)
    this.ensureAssistantMessage(data.message_id, data.model)
  }

  handleMessageChunk(data) {
    const message = this.ensureAssistantMessage(data.message_id)
    const controller = this.messageControllerFor(message)
    controller?.appendContent(data.content || "")
    this.scrollToBottom()
  }

  handleMessageComplete(data) {
    this.streaming = false
    this.currentStreamId = null
    this.setBusy(false)
    this.toggleTyping(false)
    this.setStatus("Ready")
    this.incrementTokenUsage(data.tokens)
    this.scrollToBottom()
  }

  handleError(data) {
    this.streaming = false
    this.currentStreamId = null
    this.setBusy(false)
    this.toggleTyping(false)
    this.setStatus(data.message || "An unexpected error occurred")
  }

  setBusy(busy) {
    this.streaming = busy
    this.dispatchChatState(busy ? "chat:busy" : "chat:idle")
    if (busy) this.setStatus("Waiting for assistant…")
  }

  dispatchChatState(name) {
    const inputForm = this.element.querySelector("[data-controller~='chat-input']")
    inputForm?.dispatchEvent(new window.CustomEvent(name, { bubbles: true }))
  }

  setStatus(message) {
    if (this.hasStatusTarget) {
      this.statusTarget.textContent = message
    }
  }

  toggleTyping(show) {
    if (!this.hasTypingIndicatorTarget) return

    this.typingIndicatorTarget.classList.toggle("hidden", !show)
  }

  ensureAssistantMessage(streamId, model = null) {
    const existing = this.messagesTarget.querySelector(`[data-stream-message-id="${streamId}"]`)
    if (existing) return existing

    const wrapper = document.createElement("div")
    wrapper.className = "flex justify-start"

    const article = document.createElement("article")
    article.className = "max-w-3xl rounded-[1.5rem] rounded-bl-md bg-white px-4 py-3 text-sm text-slate-900 shadow-sm ring-1 ring-slate-200"
    article.dataset.controller = "chat-message"
    article.dataset.chatMessageRoleValue = "assistant"
    article.dataset.chatMessageMarkdownValue = "true"
    article.dataset.streamMessageId = streamId

    const meta = document.createElement("div")
    meta.className = "mb-2 flex items-center gap-2"
    meta.innerHTML = `
      <span class="inline-flex items-center rounded-full bg-slate-100 px-2.5 py-1 text-xs font-semibold text-slate-600">Assistant</span>
      <span class="text-xs font-medium text-slate-400">${model || "Assistant"}</span>
      <span class="text-xs text-slate-300">just now</span>
    `

    const content = document.createElement("div")
    content.dataset.chatMessageTarget = "content"
    content.dataset.rawContent = ""

    article.append(meta, content)
    wrapper.append(article)
    this.messagesTarget.append(wrapper)
    return article
  }

  appendMessage({ role, content }) {
    const wrapper = document.createElement("div")
    wrapper.className = role === "user" ? "flex justify-end" : "flex justify-start"

    const article = document.createElement("article")
    article.className = role === "user" ?
      "ml-auto max-w-3xl rounded-[1.5rem] rounded-br-md bg-slate-900 px-4 py-3 text-sm text-white shadow-sm" :
      "max-w-3xl rounded-[1.5rem] rounded-bl-md bg-white px-4 py-3 text-sm text-slate-900 shadow-sm ring-1 ring-slate-200"

    article.innerHTML = `
      <div class="mb-2 flex items-center gap-2">
        <span class="inline-flex items-center rounded-full ${role === "user" ? "bg-slate-800 text-slate-100" : "bg-slate-100 text-slate-600"} px-2.5 py-1 text-xs font-semibold">${role === "user" ? "User" : "Assistant"}</span>
        <span class="text-xs font-medium ${role === "user" ? "text-slate-300" : "text-slate-400"}">${role === "user" ? "You" : "Assistant"}</span>
        <span class="text-xs ${role === "user" ? "text-slate-400" : "text-slate-300"}">just now</span>
      </div>
      <div class="whitespace-pre-wrap break-words leading-6">${this.escapeHtml(content)}</div>
    `

    wrapper.append(article)
    this.messagesTarget.append(wrapper)
  }

  messageControllerFor(element) {
    return this.application.getControllerForElementAndIdentifier(element, "chat-message")
  }

  incrementTokenUsage(tokens) {
    if (!this.hasTokenUsageTarget || !tokens) return

    const current = Number(this.tokenUsageTarget.textContent.replace(/[^0-9]/g, "")) || 0
    const nextValue = current + (Number(tokens.input) || 0) + (Number(tokens.output) || 0)
    this.tokenUsageTarget.textContent = nextValue.toLocaleString()
  }

  scrollToBottom() {
    if (!this.autoScroll) return

    const streamController = this.application.getControllerForElementAndIdentifier(this.containerTarget, "chat-stream")
    if (streamController) {
      streamController.scrollToBottom()
    } else {
      this.containerTarget.scrollTop = this.containerTarget.scrollHeight
    }
  }

  escapeHtml(content) {
    return content
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
  }
}
