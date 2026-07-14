import { Controller } from "@hotwired/stimulus"
import consumer from "../channels/consumer"

export default class extends Controller {
  static targets = ["container", "messages", "input", "status", "typingIndicator", "tokenUsage"]
  static values = { sessionId: Number }

  connect() {
    this.autoScroll = true
    this.streaming = false
    this.currentStreamId = null
    this.currentAttemptToolCards = []

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

    this.setBusy(true)
    this.subscription.perform("send_message", { content })
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
    case "message_created":
      this.handleMessageCreated(data)
      break
    case "message_tool_call":
      this.handleMessageToolCall(data)
      break
    case "message_tool_result":
      this.handleMessageToolResult(data)
      break
    case "message_tool_confirmation":
      this.handleMessageToolConfirmation(data)
      break
    case "message_tool_resolved":
      this.handleMessageToolResolved(data)
      break
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
    this.currentAttemptToolCards = []
    this.setStatus(`Streaming ${data.model || "assistant"} response…`)
    this.toggleTyping(true)
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
    this.removePendingAssistantMessage()
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
    const existing = this.messagesTarget.querySelector(`article[data-stream-message-id="${streamId}"]`)
    if (existing) return existing

    const wrapper = document.createElement("div")
    wrapper.className = "flex justify-start"

    const article = document.createElement("article")
    article.className = "max-w-3xl px-0 py-1 text-[15px] text-gray-900"
    article.dataset.controller = "chat-message"
    article.dataset.chatMessageRoleValue = "assistant"
    article.dataset.chatMessageMarkdownValue = "true"
    article.dataset.streamMessageId = streamId

    const meta = document.createElement("div")
    meta.className = "mb-3 flex items-center gap-2"

    const modelLabel = document.createElement("span")
    modelLabel.className = "text-xs font-medium text-gray-500"
    modelLabel.textContent = model || "Assistant"

    const timestamp = document.createElement("span")
    timestamp.className = "text-xs text-gray-400"
    timestamp.textContent = "just now"

    meta.append(modelLabel, timestamp)

    const content = document.createElement("div")
    content.className = "chat-markdown"
    content.dataset.chatMessageTarget = "content"
    content.dataset.rawContent = ""

    article.append(meta, content)
    wrapper.append(article)
    this.messagesTarget.append(wrapper)
    return article
  }

  handleMessageToolCall(data) {
    if (!data.html) return

    const card = this.buildMessageElement(data.html)
    if (!card) return

    this.messagesTarget.append(card)
    this.trackAttemptToolCard(card)
    this.setStatus(`Running ${data.tool_name || "tool"}…`)
    this.scrollToBottom()
  }

  handleMessageToolResult(data) {
    if (!data.html) return

    const card = this.buildMessageElement(data.html)
    if (!card) return

    this.messagesTarget.append(card)
    this.trackAttemptToolCard(card)
    this.scrollToBottom()
  }

  handleMessageToolConfirmation(data) {
    if (data.html) {
      const card = this.buildMessageElement(data.html)
      if (card) {
        this.messagesTarget.append(card)
        this.scrollToBottom()
      }
    }

    this.streaming = false
    this.currentStreamId = null
    this.setBusy(false)
    this.toggleTyping(false)
    this.setStatus(`Waiting for approval to run ${data.tool_name || "tool"}…`)
  }

  handleMessageToolResolved(data) {
    if (!data.html) return

    const card = this.buildMessageElement(data.html)
    if (!card) return

    const existing = this.messageElementById(data.message_id)
    if (existing) {
      existing.closest("div")?.replaceWith(card)
    } else {
      this.messagesTarget.append(card)
    }
    this.scrollToBottom()
  }

  approveToolCall(event) {
    this.resolveToolCall(event, "approve")
  }

  denyToolCall(event) {
    this.resolveToolCall(event, "deny")
  }

  resolveToolCall(event, decision) {
    const messageId = this.messageIdFor(event.target)
    if (!messageId) return

    this.setBusy(true)
    this.setStatus("Resolving confirmation…")
    this.subscription.perform("resolve_tool_call", { message_id: messageId, decision })
  }

  handleMessageCreated(data) {
    if (!data.html) return

    if (data.fallback_notice) {
      this.removeCurrentAttemptArtifacts()
    }

    const messageElement = this.buildMessageElement(data.html)
    if (!messageElement) return

    if (data.stream_message_id) {
      const existingMessage = this.messagesTarget.querySelector(`article[data-stream-message-id="${data.stream_message_id}"]`)
      if (existingMessage) {
        existingMessage.closest("div")?.replaceWith(messageElement)
        this.scrollToBottom()
        return
      }
    }

    this.messagesTarget.append(messageElement)
    this.scrollToBottom()
  }

  buildMessageElement(html) {
    const template = document.createElement("template")
    template.innerHTML = html.trim()
    return template.content.firstElementChild
  }

  removePendingAssistantMessage() {
    if (!this.currentStreamId) return

    const pendingMessage = this.messagesTarget.querySelector(`article[data-stream-message-id="${this.currentStreamId}"]`)
    if (!pendingMessage) return

    const contentTarget = pendingMessage.querySelector("[data-chat-message-target='content']")
    if (contentTarget?.dataset.rawContent) return

    pendingMessage.closest("div")?.remove()
  }

  // On a runner fallback the partial answer AND any tool_call / tool_result
  // cards the failed attempt already rendered are stale: the backend discards
  // the matching rows (FallbackLoop#discard_partial_attempt) and the fallback
  // runner produces a fresh turn. The in-flight assistant bubble is removed and
  // the tool cards this attempt appended (tracked in currentAttemptToolCards)
  // are torn down, so the UI never lingers on tool activity that no longer
  // exists. currentStreamId is cleared so a late chunk for the old stream
  // cannot resurrect the removed bubble before the next message_start reassigns
  // it.
  removeCurrentAttemptArtifacts() {
    this.removeCurrentAssistantMessage()
    this.removeCurrentAttemptToolCards()
  }

  // Tool cards appended during the in-flight attempt. Reset on each
  // message_start so a prior turn's cards are never touched, and cleared again
  // here after a fallback so the fallback attempt's cards (if any) start fresh.
  trackAttemptToolCard(card) {
    this.currentAttemptToolCards ||= []
    this.currentAttemptToolCards.push(card)
  }

  removeCurrentAttemptToolCards() {
    (this.currentAttemptToolCards || []).forEach((card) => card.remove())
    this.currentAttemptToolCards = []
  }

  // On a runner fallback the partial answer from the failed runner is discarded
  // unconditionally (unlike removePendingAssistantMessage, which preserves a
  // bubble that already streamed content): the fallback runner produces a fresh
  // answer, so any partial text from the failed attempt is stale. currentStreamId
  // is cleared so a late chunk for the old stream cannot resurrect the removed
  // bubble before the next message_start assigns a new id.
  removeCurrentAssistantMessage() {
    if (!this.currentStreamId) return

    const pendingMessage = this.messagesTarget.querySelector(`article[data-stream-message-id="${this.currentStreamId}"]`)
    pendingMessage?.closest("div")?.remove()
    this.currentStreamId = null
  }

  messageElementById(messageId) {
    return this.messagesTarget.querySelector(`article[data-message-id="${messageId}"]`)
  }

  messageIdFor(element) {
    const container = element.closest("[data-message-id]")
    return container?.dataset.messageId
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
}
