# frozen_string_literal: true

module ChatSessions
  # Shared retry harness for the chat agent loop. Runs `AgentLoop` and, when the
  # active runner raises an `AgentHarness::Error` (e.g. a provider rate limit),
  # switches to the next configured fallback runner and retries until one
  # succeeds or no untried fallback remains (then the original error re-raises).
  #
  # Hosts (SendMessage, ResolveToolCall) must expose `chat_session`,
  # `llm_client`, `on_chunk`, `on_message_persisted`, and `stream_message_id`,
  # and own the `@llm_client` ivar (it is reset on each switch so the next
  # attempt rebuilds the client for the new runner).
  module FallbackLoop
    private

    def run_with_fallbacks
      attempted_runners = [ chat_session.runner ].compact

      loop do
        checkpoint = chat_session.messages.maximum(:id)
        @llm_client ||= ChatSessions::BuildLlmClient.call(chat_session: chat_session)
        return ChatSessions::AgentLoop.new(**fallback_loop_kwargs).run
      rescue AgentHarness::Error => e
        fallback_runner = ChatSessions::FallbackRunners.for(chat_session: chat_session, excluding: attempted_runners).first
        raise unless fallback_runner

        attempted_runners << fallback_runner
        discard_partial_attempt(checkpoint)
        switch_to_fallback_runner(fallback_runner, e)
      end
    end

    def fallback_loop_kwargs
      {
        chat_session: chat_session,
        llm_client: llm_client,
        on_chunk: on_chunk,
        on_message_persisted: on_message_persisted,
        stream_message_id: stream_message_id
      }
    end

    # Remove any assistant/tool messages the failed attempt persisted before it
    # raised, so the fallback runner is not replayed a half-finished turn (which
    # would duplicate the assistant turn or re-feed dispatched tool calls). The
    # user message and any prior, settled turns precede the checkpoint and are
    # preserved.
    def discard_partial_attempt(checkpoint)
      scope = chat_session.messages
      scope = scope.where("id > ?", checkpoint) if checkpoint
      scope.delete_all
    end

    # Switch the session to the fallback runner and record the user-facing
    # notice atomically, so a failure persisting the notice rolls back the
    # runner switch (the session never ends up silently on a new runner with no
    # explanation). The broadcast fires only after the transaction commits.
    def switch_to_fallback_runner(runner, error)
      message = chat_session.transaction do
        ChatSessions::FallbackRunners.switch!(chat_session: chat_session, runner: runner)
        chat_session.messages.create!(
          role: "assistant",
          content: ChatSessions::FallbackRunners.notice_for(error: error, runner: runner),
          metadata: { "fallback_notice" => true }
        )
      end

      @llm_client = nil
      on_message_persisted&.call(message)
      message
    end
  end
end
