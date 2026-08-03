import { Controller } from "@hotwired/stimulus"
import consumer from "../channels/consumer"

export default class extends Controller {
  static targets = ["container", "messages", "input", "status", "typingIndicator", "tokenUsage", "capabilityBadge", "capabilityPanel", "capabilityLabel", "capabilityIcon", "capabilityRepos"]
  static values = { sessionId: Number }

  connect() {
    this.autoScroll = true
    this.streaming = false
    this.currentStreamId = null
    this.currentAttemptToolCards = []

    this.subscription = consumer.subscriptions.create(
      { channel: "ChatChannel", session_id: this.sessionIdValue },
      {
        connected: () => this.handleConnected(),
        disconnected: () => this.handleDisconnected(),
        rejected: () => this.handleRejected(),
        received: (data) => this.handleEvent(data)
      }
    )
  }

  disconnect() {
    this.subscription?.unsubscribe()
  }

  // A dropped/rejected connection mid-turn strands the streaming lock: the
  // terminators that normally release it (message_complete / error /
  // message_tool_confirmation) travel over the socket we just lost, so any
  // emitted during the gap are gone. Without recovery, `sendMessage` no-ops
  // forever (it guards on `streaming`) and the only escape is a page reload.
  // Reset on disconnect/reconnect/reject so the input recovers. No-op when no
  // turn is in flight, so stable connections and the initial connect — where
  // dispatching chat:idle would also auto-focus the textarea — are unaffected.
  handleConnected() {
    this.resetStreamingState()
    this.setStatus("Connected")
  }

  handleDisconnected() {
    this.resetStreamingState()
    this.setStatus("Disconnected")
  }

  handleRejected() {
    this.resetStreamingState()
    this.setStatus("Subscription rejected")
  }

  resetStreamingState() {
    if (!this.streaming) return

    this.removePendingAssistantMessage()
    this.streaming = false
    this.currentStreamId = null
    this.currentAttemptToolCards = []
    this.toggleTyping(false)
    this.dispatchChatState("chat:idle")
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
    case "message_deleted":
      this.handleMessageDeleted(data)
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
    case "capability_changed":
      this.handleCapabilityChanged(data)
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

  // Updates the workspace-capability badge in place when the background
  // provisioner finishes (RDR-037), so the inline→container transition is
  // visible without a page reload. Conversation history is unaffected.
  handleCapabilityChanged(data) {
    const capability = data.container_capability
    if (!capability) return

    const badgeStyles = {
      none: "bg-gray-100 text-gray-600",
      pending: "bg-amber-100 text-amber-800",
      provisioning: "bg-amber-100 text-amber-800",
      ready: "bg-green-100 text-green-700",
      failed: "bg-rose-100 text-rose-700",
      stopped: "bg-gray-100 text-gray-600"
    }
    const iconStyles = {
      none: "text-gray-500 fill-current",
      pending: "text-amber-500 fill-current",
      provisioning: "text-amber-500 fill-current",
      ready: "text-green-500 fill-current",
      failed: "text-rose-500 fill-current",
      stopped: "text-gray-500 fill-current"
    }
    const badgeClasses = badgeStyles[capability] || badgeStyles.none
    const iconClasses = iconStyles[capability] || iconStyles.none

    this.capabilityBadgeTargets.forEach((badge) => {
      badge.textContent = data.container_capability_label || capability.charAt(0).toUpperCase() + capability.slice(1)
      badge.className = `inline-flex items-center rounded-full px-2 py-1 text-xs font-medium ${badgeClasses}`
      badge.dataset.capability = capability
    })

    this.capabilityPanelTargets.forEach((panel) => {
      panel.dataset.chatCapability = capability
    })

    this.capabilityLabelTargets.forEach((label) => {
      label.textContent = data.container_capability_label || capability
    })

    this.capabilityIconTargets.forEach((icon) => {
      this.setElementClassName(icon, `h-4 w-4 ${iconClasses}`)
    })

    this.updateCapabilityActions(capability)
    this.updateCapabilityRepos(data.cloned_repos || [])

    if (capability === "ready") {
      this.setStatus("Workspace ready")
    } else if (capability === "failed") {
      this.setStatus("Workspace unavailable")
    }
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
      this.renderedMessageElement(existing)?.replaceWith(card)
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

    if (data.message_id) {
      const existingMessage = this.messageElementById(data.message_id)
      if (existingMessage) {
        this.renderedMessageElement(existingMessage)?.replaceWith(messageElement)
        this.scrollToBottom()
        return
      }
    }

    if (data.stream_message_id) {
      const existingMessage = this.messagesTarget.querySelector(`article[data-stream-message-id="${data.stream_message_id}"]`)
      if (existingMessage) {
        this.renderedMessageElement(existingMessage)?.replaceWith(messageElement)
        this.scrollToBottom()
        return
      }
    }

    this.messagesTarget.append(messageElement)
    this.scrollToBottom()
  }

  handleMessageDeleted(data) {
    if (!data.message_id) return

    const messageElement = this.messageElementById(data.message_id)
    this.renderedMessageElement(messageElement)?.remove()
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
    return this.messagesTarget.querySelector(`[data-message-id="${messageId}"]`)
  }

  renderedMessageElement(element) {
    return element?.closest("details, div.flex.justify-start, div.justify-end, div.justify-center")
  }

  messageIdFor(element) {
    const container = element.closest("[data-message-id]")
    return container?.dataset.messageId
  }

  messageControllerFor(element) {
    return this.application.getControllerForElementAndIdentifier(element, "chat-message")
  }

  updateCapabilityActions(capability) {
    this.element.querySelectorAll("[data-chat-capability-ready-only]").forEach((element) => {
      element.classList.toggle("hidden", capability !== "ready")
    })

    this.element.querySelectorAll("[data-chat-capability-stopped-only]").forEach((element) => {
      element.classList.toggle("hidden", capability !== "stopped")
    })
  }

  updateCapabilityRepos(repos) {
    this.capabilityReposTargets.forEach((container) => {
      if (repos.length === 0) {
        container.innerHTML = "<p class=\"rounded-md bg-white px-3 py-2 text-sm text-gray-500 ring-1 ring-gray-200\">No repos cloned yet.</p>"
        return
      }

      container.innerHTML = repos.map((repo) => {
        const staleBadge = repo.stale ? "<span class=\"inline-flex items-center rounded-full bg-rose-100 px-2 py-0.5 text-[11px] font-medium text-rose-700\">stale</span>" : ""
        const staleReason = repo.stale_reason ? `<p class="mt-1 text-xs text-rose-600">${this.escapeHtml(repo.stale_reason)}</p>` : ""

        return `<div class="rounded-md bg-white px-3 py-2 text-sm text-gray-700 ring-1 ring-gray-200">
          <div class="flex items-center justify-between gap-2">
            <p class="font-medium text-gray-900">${this.escapeHtml(repo.project_full_name || repo.project_name || `Project #${repo.project_id}`)}</p>
            ${staleBadge}
          </div>
          <p class="mt-1 font-mono text-xs text-gray-500">${this.escapeHtml(repo.path || "")}</p>
          <p class="mt-1 text-xs text-gray-500">Clone identity: ${this.escapeHtml(repo.token_identity || "unknown")}</p>
          ${staleReason}
        </div>`
      }).join("")
    })
  }

  escapeHtml(value) {
    return String(value)
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll("\"", "&quot;")
      .replaceAll("'", "&#39;")
  }

  setElementClassName(element, className) {
    if (typeof element.setAttribute === "function") {
      element.setAttribute("class", className)
      return
    }

    element.className = className
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
