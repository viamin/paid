# Chat Transcript Navigation Specs

> Testable claims for interactive chat transcript navigation. Status markers:
> `[x]` implemented, `[ ]` gap, `[D]` deferred.

- [x] **CHAT-SCROLL-001** — When a user selects either "Jump to latest"
  control, the chat transcript SHALL smoothly scroll to the container-relative
  top of the last assistant text response, excluding tool-call cards. On a
  forward visit, it SHALL place that same response top in view without
  animation; on a browser or Turbo restoration visit, it SHALL preserve the
  user's transcript position. Because Turbo restores only the document scroll
  offset, the controller SHALL persist and restore its overflow container
  position per chat session. When no assistant text response exists, either behavior
  SHALL fall back to the bottom of the transcript. After an on-load jump, the
  controller SHALL recompute control visibility so the sticky control is hidden
  when the fallback has reached the bottom.

  *Tests:* `spec/lib/chat_controller_node_harness_spec.rb`
  (`testScrollToLatestResponseSmoothScrollsToAnchor`,
  `testScrollToLatestResponseFallsBackToBottom`,
  `testJumpToLatestResponseOnLoadSetsScrollTopInstantly`,
  `testDisconnectRemembersTranscriptScrollPosition`,
  `testJumpToLatestResponseOnLoadRestoresTranscriptPosition`,
  `testJumpToLatestResponseOnLoadFallsBackToBottom`,
  `testJumpToLatestResponseOnLoadUpdatesStickyControl`).
  *Code:* `app/javascript/controllers/chat_controller.js#scrollToLatestResponse`,
  `#jumpToLatestResponseOnLoad`, `#latestResponseScrollTop`,
  `#lastAssistantTextResponse`, `#anchorScrollTopWithinContainer`,
  `#handleScroll`.
