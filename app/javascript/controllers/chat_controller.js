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
    article.className = "max-w-3xl rounded-[1.5rem] rounded-bl-md bg-white px-4 py-3 text-sm text-slate-900 shadow-sm ring-1 ring-slate-200"
    article.dataset.controller = "chat-message"
    article.dataset.chatMessageRoleValue = "assistant"
    article.dataset.chatMessageMarkdownValue = "true"
    article.dataset.streamMessageId = streamId

    const meta = document.createElement("div")
    meta.className = "mb-2 flex items-center gap-2"

    const roleBadge = document.createElement("span")
    roleBadge.className = "inline-flex items-center rounded-full bg-slate-100 px-2.5 py-1 text-xs font-semibold text-slate-600"
    roleBadge.textContent = "Assistant"

    const modelLabel = document.createElement("span")
    modelLabel.className = "text-xs font-medium text-slate-400"
    modelLabel.textContent = model || "Assistant"

    const timestamp = document.createElement("span")
    timestamp.className = "text-xs text-slate-300"
    timestamp.textContent = "just now"

    meta.append(roleBadge, modelLabel, timestamp)

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
    this.setStatus(`Running ${data.tool_name || "tool"}…`)
    this.scrollToBottom()
  }

  handleMessageToolResult(data) {
    if (!data.html) return

    const card = this.buildMessageElement(data.html)
    if (!card) return

    this.messagesTarget.append(card)
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
      this.removeCurrentAssistantMessage()
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

  removeCurrentAssistantMessage() {
    if (!this.currentStreamId) return

    const pendingMessage = this.messagesTarget.querySelector(`article[data-stream-message-id="${this.currentStreamId}"]`)
    pendingMessage?.closest("div")?.remove()
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
