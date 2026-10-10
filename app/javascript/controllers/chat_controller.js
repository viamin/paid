import { Controller } from "@hotwired/stimulus"
import consumer from "../channels/consumer"

export default class extends Controller {
  static targets = ["backToTop", "stickyJumpToLatest", "container", "messages", "input", "status", "typingIndicator", "tokenUsage", "capabilityBadge", "capabilityPanel", "capabilityLabel", "capabilityIcon", "capabilityRepos"]
  static values = { sessionId: Number }

  connect() {
    this.autoScroll = true
    this.streaming = false
    this.disconnectedMidTurn = false
    this.currentStreamId = null
    this.expectedStreamSequence = 1
    this.ignoredStreamIds = new Set()
    this.pendingContent = null
    this.currentAttemptToolCards = []
    this.scrollAnimationId = null
    this.initialJumpAnimationId = null
    this.boundUpdateViewportHeight = () => this.updateViewportHeight()

    this.subscription = consumer.subscriptions.create(
      { channel: "ChatChannel", session_id: this.sessionIdValue },
      {
        connected: () => this.handleConnected(),
        disconnected: () => this.handleDisconnected(),
        rejected: () => this.handleRejected(),
        received: (data) => this.handleEvent(data)
      }
    )

    window.addEventListener("resize", this.boundUpdateViewportHeight)
    this.updateViewportHeight()
    this.handleScroll()
    // Land the user on the top of the last assistant response on a forward
    // navigation so they don't have to scroll or click "Jump to input" to
    // catch up on the latest answer. Restoration visits recover the saved
    // transcript position instead, because Turbo restores only document
    // scroll and would otherwise show the oldest messages (#4174).
    // chat-message controllers connect after this controller in document
    // order and synchronously render markdown, which can move the response
    // anchor. Wait one frame to measure the final transcript layout.
    this.initialJumpAnimationId = requestAnimationFrame(() => {
      this.initialJumpAnimationId = null
      this.jumpToLatestResponseOnLoad()
    })
  }

  disconnect() {
    this.rememberTranscriptScrollPosition()
    this.subscription?.unsubscribe()
    window.removeEventListener("resize", this.boundUpdateViewportHeight)
    if (this.scrollAnimationId) cancelAnimationFrame(this.scrollAnimationId)
    if (this.initialJumpAnimationId != null) cancelAnimationFrame(this.initialJumpAnimationId)
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
    // handleDisconnected() always runs before a real reconnect's connected()
    // callback, and it already reset `this.streaming` to false via
    // resetStreamingState(). Reading `this.streaming` here would therefore
    // always see false, so the gap-recovery resync below would never fire —
    // the "was a turn in flight when we dropped" signal has to survive that
    // earlier reset. disconnectedMidTurn carries it across the gap.
    const resuming = this.disconnectedMidTurn
    this.disconnectedMidTurn = false
    this.resetStreamingState()
    this.setStatus("Connected")
    // resetStreamingState tears down any orphaned streaming bubble, but a gap
    // wide enough to drop the connection can also drop the terminal broadcast
    // (message_created / message_complete / error) entirely — those travel
    // over the socket we just lost. Only resync when a turn was actually in
    // flight, so a stable connection's initial connect stays a no-op.
    if (resuming) this.resyncTranscript()
  }

  handleDisconnected() {
    this.disconnectedMidTurn = this.streaming
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

  // @spec CHAT-API-023
  // Replays any messages persisted while the connection was down, through the
  // same handleMessageCreated path a live broadcast uses, so the transcript
  // converges on the persisted rows instead of silently missing a turn that
  // completed (or progressed) during the gap (#4225). No-ops when there is
  // nothing rendered yet to resync from (e.g. the gap covers the session's
  // very first message) — a full reload remains the backstop for that case.
  resyncTranscript() {
    if (!this.hasMessagesTarget) return

    const sinceId = this.lastRenderedMessageId()
    if (sinceId == null) return

    this.replayRecentMessages(sinceId)
      .then(() => this.scrollToBottom())
      .catch((error) => {
        globalThis.console?.error?.("chat#resyncTranscript failed", error)
      })
  }

  replayRecentMessages(sinceId) {
    return this.fetchRecentMessages(sinceId)
      .then(({ messages, hasMore }) => {
        messages.forEach((message) => this.handleMessageCreated(message))

        const lastMessage = messages.at(-1)
        return hasMore && lastMessage ? this.replayRecentMessages(lastMessage.message_id) : null
      })
  }

  fetchRecentMessages(sinceId) {
    return fetch(`/chat/${this.sessionIdValue}/recent_messages?since=${encodeURIComponent(sinceId)}`, {
      headers: { Accept: "application/json" },
      credentials: "same-origin"
    })
      .then((response) => (response.ok ? response.json() : { messages: [], has_more: false }))
      .then((data) => ({ messages: data.messages || [], hasMore: data.has_more === true }))
  }

  // The highest data-message-id currently rendered — every persisted message
  // partial carries one (see app/views/chat_messages/_bubble.html.erb), and
  // ids are assigned in creation order, so the max is the resync cursor.
  lastRenderedMessageId() {
    if (!this.hasMessagesTarget) return null

    let max = null
    this.messagesTarget.querySelectorAll("[data-message-id]").forEach((element) => {
      const id = Number(element.dataset.messageId)
      if (Number.isFinite(id) && (max === null || id > max)) max = id
    })
    return max
  }

  sendMessage(event) {
    const content = event.detail.content?.trim()
    if (!content || this.streaming) return

    // Retained so a rejected send (e.g. a token-limit error) can restore the
    // text into the input instead of silently discarding it — the textarea
    // is already cleared optimistically by chat-input#send at this point.
    this.pendingContent = content
    this.setBusy(true)
    this.subscription.perform("send_message", { content })
  }

  submitForm(event) {
    event.target.form?.requestSubmit()
  }

  saveSettings(event) {
    const form = event.currentTarget
    const status = form.querySelector("[data-chat-settings-status]")
    if (status) status.textContent = "Saving…"
    form.requestSubmit()
  }

  settingsSubmitted(event) {
    // @spec CHAT-SESSION-PREFERENCES-002
    const status = event.currentTarget.querySelector("[data-chat-settings-status]")
    if (status) status.textContent = event.detail.success ? "Chat settings saved" : "Could not save chat settings"
  }

  submitTitleOnBlur(event) {
    const input = event.target
    if (input.name?.endsWith("[title]")) {
      input.form?.requestSubmit()
    }
  }

  // Measured document-relative, not viewport-relative: getBoundingClientRect
  // alone shrinks (and clamps to 0) whenever the page is scrolled as the
  // controller connects — a Turbo restoration visit, or a user who scrolls
  // before JS boots. That understates the offset, sizes the panel taller than
  // the viewport, and hands the scroll role back to the document, which is the
  // exact failure the bound exists to prevent. The document offset is
  // scroll-invariant, so the panel is bound the same on every visit.
  updateViewportHeight() {
    const scrollY = globalThis.window?.scrollY || 0
    const top = Math.max(this.element.getBoundingClientRect().top + scrollY, 0)
    this.element.style.setProperty("--chat-panel-offset-top", `${Math.ceil(top)}px`)
  }

  handleScroll() {
    if (!this.hasContainerTarget) return

    const threshold = 48
    const distanceFromBottom = this.containerTarget.scrollHeight - this.containerTarget.scrollTop - this.containerTarget.clientHeight
    this.autoScroll = distanceFromBottom <= threshold

    if (this.hasBackToTopTarget) {
      const show = this.containerTarget.scrollTop > 200
      this.backToTopTarget.classList.toggle("opacity-100", show)
      this.backToTopTarget.classList.toggle("pointer-events-auto", show)
      this.backToTopTarget.classList.toggle("opacity-0", !show)
      this.backToTopTarget.classList.toggle("pointer-events-none", !show)
    }

    if (this.hasStickyJumpToLatestTarget) {
      const anchor = this.lastAssistantTextResponse()
      const showJump = anchor
        // Anchor-relative: show only when the user has scrolled past the
        // start of the last response. A fixed pixel threshold would surface
        // the button even when a click would be a no-op (#4174).
        ? anchor.getBoundingClientRect().top < this.containerTarget.getBoundingClientRect().top
        // No anchor means the fallback target is the bottom of the transcript.
        // Reuse the auto-scroll threshold so the button mirrors the bottom-
        // visibility rule used elsewhere.
        : distanceFromBottom > threshold
      this.stickyJumpToLatestTarget.classList.toggle("opacity-100", showJump)
      this.stickyJumpToLatestTarget.classList.toggle("pointer-events-auto", showJump)
      this.stickyJumpToLatestTarget.classList.toggle("opacity-0", !showJump)
      this.stickyJumpToLatestTarget.classList.toggle("pointer-events-none", !showJump)
    }
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
    if (!data.message_id || data.message_id === this.currentStreamId) return

    this.ignoredStreamIds ||= new Set()
    this.removePendingAssistantMessage()
    this.currentStreamId = data.message_id
    this.expectedStreamSequence = 1
    this.ignoredStreamIds.delete(data.message_id)
    this.streaming = true
    this.currentAttemptToolCards = []
    this.setStatus(`Streaming ${data.model || "assistant"} response…`)
    this.toggleTyping(true)
  }

  // @spec CHAT-API-022 @spec CHAT-API-023
  // A mid-stream disconnect clears currentStreamId (resetStreamingState), but
  // the turn is still in flight server-side — ProcessMessageJob only ever
  // broadcasts message_start once, so reconnecting resumes receiving chunks
  // for that same stream id with no new message_start to re-arm tracking.
  // ensureAssistantMessage recreates the bubble regardless of tracking state,
  // so an unowned chunk re-arms that stream. Once another stream is active,
  // however, late chunks from the disconnected stream must not take ownership
  // or a later terminal event could tear down the new stream's bubble (#4225).
  handleMessageChunk(data) {
    if (data.message_id == null) return

    if (!this.currentStreamId) {
      if (this.ignoredStreamIds.has(data.message_id)) return
      this.currentStreamId = data.message_id
      this.streaming = true
    }
    if (this.ignoredStreamIds.has(data.message_id) || !this.streamEventMatches(data)) return

    const sequence = Number(data.sequence)
    if (!Number.isInteger(sequence) || sequence !== this.expectedStreamSequence) {
      this.invalidateStream(data.message_id)
      return
    }

    const message = this.ensureAssistantMessage(data.message_id)
    const controller = this.messageControllerFor(message)
    controller?.appendContent(data.content || "")
    this.expectedStreamSequence += 1
    this.scrollToBottom()
  }

  // @spec CHAT-API-022 @spec CHAT-API-023
  handleMessageComplete(data) {
    const streamId = data.message_id || this.currentStreamId
    this.removeStreamingMessage(streamId)
    this.ignoredStreamIds ||= new Set()
    this.ignoredStreamIds.delete(streamId)
    if (data.message_id && this.currentStreamId && data.message_id !== this.currentStreamId) return
    this.streaming = false
    this.currentStreamId = null
    this.pendingContent = null
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
    const streamId = data.message_id || this.currentStreamId
    this.removeStreamingMessage(streamId)
    this.ignoredStreamIds ||= new Set()
    this.ignoredStreamIds.delete(streamId)
    if (data.message_id && this.currentStreamId && data.message_id !== this.currentStreamId) return
    this.streaming = false
    this.currentStreamId = null
    this.setBusy(false)
    this.toggleTyping(false)
    // Only a token-limit rejection (carrying limit_type) happens before
    // persist_user_message — every other error path (provider fallback
    // exhaustion, rate limits, unexpected errors) fires after the user
    // message was already persisted and rendered via its own
    // message_created broadcast, so restoring here would duplicate it.
    if (data.limit_type) this.restorePendingContent()
    this.setStatus(data.message || "An unexpected error occurred")
  }

  // Puts the rejected turn's text back into the input (e.g. after a
  // token-limit rejection) so it can be copied into a new chat or retried
  // once the limit changes, instead of being silently lost. Dispatching
  // "input" re-triggers chat-input's own resize/char-count handling.
  restorePendingContent() {
    if (!this.pendingContent || !this.hasInputTarget) return

    this.inputTarget.value = this.pendingContent
    this.inputTarget.dispatchEvent(new window.Event("input", { bubbles: true }))
    this.pendingContent = null
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
    if (!this.streamEventMatches(data)) return

    // @spec CHAT-API-023
    // A write-tool pause can follow reasoning/narration text that already
    // streamed into the bubble but was never persisted as its own message
    // (the turn isn't done — it's paused awaiting approval), so it would
    // otherwise orphan at the transcript tail until the next turn (#4225).
    this.removePendingAssistantMessage()

    if (data.html) {
      const card = this.buildMessageElement(data.html)
      if (card) {
        this.messagesTarget.append(card)
        this.scrollToBottom()
      }
    }

    this.streaming = false
    this.currentStreamId = null
    this.pendingContent = null
    this.setBusy(false)
    this.toggleTyping(false)
    this.setStatus(`Waiting for approval to run ${data.tool_name || "tool"}…`)
  }

  streamEventMatches(data) {
    return this.currentStreamId === (data.stream_message_id || data.message_id)
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

  // @spec CHAT-API-022 @spec CHAT-API-023
  // Unconditional by design: every terminal path that calls this (message
  // completion, tool-confirmation pause, provider error, reconnect) either
  // already replaced the bubble with a persisted message_created — in which
  // case the data-stream-message-id selector below finds nothing and this is
  // a no-op — or the turn ended with no replacement, in which case the
  // streamed text was never persisted and must not linger as a frozen
  // partial at the transcript tail (#4225). Preserving content here is
  // exactly backwards: it only preserves text in the one case it is stale.
  removePendingAssistantMessage() {
    this.removeStreamingMessage(this.currentStreamId)
  }

  removeStreamingMessage(streamId) {
    if (!streamId) return

    const pendingMessage = this.messagesTarget.querySelector(`article[data-stream-message-id="${streamId}"]`)
    pendingMessage?.closest("div")?.remove()
  }

  invalidateStream(streamId) {
    this.ignoredStreamIds.add(streamId)
    this.removeStreamingMessage(streamId)
    this.setStatus("Waiting for saved response…")
  }

  // On a runner fallback the partial answer AND any tool_call / tool_result
  // cards the failed attempt already rendered are stale: the backend discards
  // the matching rows (FallbackLoop#discard_partial_attempt) and the fallback
  // runner produces a fresh turn. The in-flight assistant bubble is removed and
  // the tool cards this attempt appended (tracked in currentAttemptToolCards)
  // are torn down, so the UI never lingers on tool activity that no longer
  // exists. The stream ID stays active: fallback chunks share its contiguous
  // sequence and render into a fresh bubble after the stale one is removed.
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
  // unconditionally: the fallback runner produces a fresh answer, so any
  // partial text from the failed attempt is stale. Keeping currentStreamId
  // lets the fallback attempt continue streaming into a fresh bubble.
  removeCurrentAssistantMessage() {
    if (!this.currentStreamId) return

    const pendingMessage = this.messagesTarget.querySelector(`article[data-stream-message-id="${this.currentStreamId}"]`)
    pendingMessage?.closest("div")?.remove()
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
    this.toggleCapabilityActions("[data-chat-capability-ready-only]", capability === "ready")
    this.toggleCapabilityActions("[data-chat-capability-stopped-only]", capability === "stopped")
  }

  // Revealing an action inside a collapsed disclosure reveals nothing, so
  // unfold the Workspace <details> with it. Without this a workspace that
  // stops mid-session hides its own "Reopen with workspace" recovery button.
  // The ready-only clone control is nested inside Workspace options; opening
  // only that nested disclosure still leaves it unreachable when Workspace is
  // collapsed.
  // Only unfold on an actual hidden -> shown transition — same-state snapshot
  // broadcasts (e.g. a clone_manifest rebroadcast that still carries
  // container_capability: "ready") would otherwise force a disclosure the user
  // just collapsed back open.
  toggleCapabilityActions(selector, show) {
    this.element.querySelectorAll(selector).forEach((element) => {
      const wasHidden = element.classList.contains("hidden")
      element.classList.toggle("hidden", !show)
      if (show && wasHidden) element.closest("[data-chat-workspace-disclosure]")?.setAttribute("open", "")
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
    if (!tokens) return

    const delta = (Number(tokens.input) || 0) + (Number(tokens.output) || 0)
    if (!delta) return

    this.tokenUsageTargets.forEach((target) => {
      const current = Number(target.textContent.replace(/[^0-9]/g, "")) || 0
      target.textContent = (current + delta).toLocaleString()
    })
  }

  scrollToBottom() {
    if (!this.hasContainerTarget) return
    if (!this.autoScroll) return

    const streamController = this.application.getControllerForElementAndIdentifier(this.containerTarget, "chat-stream")
    if (streamController) {
      streamController.scrollToBottom()
    } else {
      this.containerTarget.scrollTop = this.containerTarget.scrollHeight
    }
  }

  scrollToTop() {
    this.smoothScrollTo(0)
  }

  scrollToInput() {
    if (!this.hasContainerTarget) return
    this.smoothScrollTo(this.containerTarget.scrollHeight)
  }

  // @spec CHAT-SCROLL-001 — Jump to the top of the last assistant text
  // response (smoothly). Falls back to the bottom of the container when the
  // chat has no assistant text message yet — a new chat, or one whose last
  // turn is a user message — so the click still does something useful.
  scrollToLatestResponse() {
    if (!this.hasContainerTarget) return
    this.smoothScrollTo(this.latestResponseScrollTop())
  }

  // @spec CHAT-SCROLL-001 — On a forward navigation into the chat, jump
  // instantly (no animation) to the same anchor the sticky button would
  // target, so users land on the latest assistant answer without having to
  // scroll. Turbo restores the document scroll position but not this overflow
  // container, so restoration visits recover the saved transcript position
  // when it is available and otherwise use the forward-visit target.
  jumpToLatestResponseOnLoad() {
    if (!this.hasContainerTarget) return
    if (this.isTurboRestorationVisit() && this.restoreTranscriptScrollPosition()) {
      this.handleScroll()
      return
    }

    const target = this.latestResponseScrollTop()
    if (target == null) return
    this.containerTarget.scrollTop = target
    this.handleScroll()
  }

  latestResponseScrollTop() {
    if (!this.hasContainerTarget) return null

    const anchor = this.lastAssistantTextResponse()
    if (anchor) return this.anchorScrollTopWithinContainer(anchor)

    return this.containerTarget.scrollHeight
  }

  // @spec CHAT-SCROLL-001 @spec CHAT-API-023
  // The last persisted assistant text message inside the transcript — tool
  // calls render without that flag and are skipped. Streaming bubbles from
  // ensureAssistantMessage carry data-stream-message-id and are explicitly
  // excluded: they are not yet persisted (and may never be, if the turn ends
  // in an error or reconnect), so anchoring "Jump to latest" on one would
  // land on text that can vanish or get rewritten under the user (#4225).
  // While a turn is actively streaming this falls back to the previous
  // persisted response, or null if there isn't one yet.
  lastAssistantTextResponse() {
    if (!this.hasMessagesTarget) return null
    const articles = this.messagesTarget.querySelectorAll(
      'article[data-message-id][data-chat-message-role-value="assistant"][data-chat-message-markdown-value="true"]'
    )
    return articles[articles.length - 1] || null
  }

  // Container-relative scrollTop of an anchor inside `messagesTarget`.
  // offsetTop would be cheaper but is unreliable: the messages wrapper can
  // nest flex/justify items (system-prompt disclosure, tool-call cards,
  // streaming bubbles), so the anchor's offsetTop is measured against the
  // nearest positioned ancestor, not the scroll container. Walking the rect
  // gives the real container-relative offset (#4174).
  anchorScrollTopWithinContainer(anchor) {
    if (!this.hasContainerTarget) return null
    const containerRect = this.containerTarget.getBoundingClientRect()
    const anchorRect = anchor.getBoundingClientRect()
    return this.containerTarget.scrollTop + (anchorRect.top - containerRect.top)
  }

  // True when the page was re-entered through browser history (back/forward)
  // or a Turbo restoration visit. Native browser restoration preserves an
  // element's position; Turbo restoration instead uses the saved position.
  isTurboRestorationVisit() {
    const visit = globalThis.Turbo?.navigator?.currentVisit
    if (visit) return visit.action === "restore"

    const navEntry = globalThis.performance?.getEntriesByType?.("navigation")?.[0]
    return navEntry?.type === "back_forward"
  }

  // Turbo snapshots restore the document's scroll position but reset this
  // overflow container to its initial position. Keep the position scoped to
  // the chat session so Back/Forward returns readers to the same response.
  rememberTranscriptScrollPosition() {
    if (!this.hasContainerTarget) return

    try {
      globalThis.sessionStorage?.setItem(this.transcriptScrollStorageKey(), String(this.containerTarget.scrollTop))
    } catch {
      // sessionStorage is unavailable in some private-browsing contexts.
    }
  }

  restoreTranscriptScrollPosition() {
    try {
      const saved = globalThis.sessionStorage?.getItem(this.transcriptScrollStorageKey())
      if (saved == null || saved.trim() === "") return false

      const position = Number(saved)
      if (!Number.isFinite(position) || position < 0) return false

      this.containerTarget.scrollTop = position
      return true
    } catch {
      return false
    }
  }

  transcriptScrollStorageKey() {
    return `paid:chat-scroll:${this.sessionIdValue}`
  }

  // Element.scrollTo({ behavior: "smooth" }) is unreliable on iOS Safari,
  // especially in PWA / standalone mode — the call silently does nothing.
  // A requestAnimationFrame loop that sets scrollTop directly works on every
  // browser because scrollTop assignment is universally supported.
  smoothScrollTo(target) {
    if (!this.hasContainerTarget) return
    if (this.scrollAnimationId) cancelAnimationFrame(this.scrollAnimationId)

    const container = this.containerTarget
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      container.scrollTop = target
      return
    }

    const start = container.scrollTop
    const distance = target - start
    if (distance === 0) return

    const duration = 300
    const startTime = performance.now()

    const step = (now) => {
      const progress = Math.min((now - startTime) / duration, 1)
      const eased = progress < 0.5 ? 2 * progress * progress : 1 - (-2 * progress + 2) ** 2 / 2
      container.scrollTop = start + distance * eased
      if (progress < 1) {
        this.scrollAnimationId = requestAnimationFrame(step)
      } else {
        this.scrollAnimationId = null
      }
    }

    this.scrollAnimationId = requestAnimationFrame(step)
  }
}
