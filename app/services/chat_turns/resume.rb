# frozen_string_literal: true

module ChatTurns
  # Resumes a stalled chat turn (#4680) from its last durable checkpoint:
  # re-runs the agent loop against the conversation already persisted for
  # `chat_turn.user_message`, rather than replaying the turn from scratch —
  # whatever tool calls and results already exist in the transcript are left
  # untouched and are not re-dispatched. Mirrors
  # ChatSessions::ResumeRateLimited's use of FallbackLoop.
  class Resume
    include ChatSessions::FallbackLoop

    attr_reader :chat_turn, :chat_session, :actor, :llm_client, :on_chunk, :stream_message_id,
      :transport_attempt_message

    def initialize(chat_turn:, actor: nil, on_chunk: nil, on_message_persisted: nil, llm_client: nil, stream_message_id: nil)
      @chat_turn = chat_turn
      @chat_session = chat_turn.chat_session
      @actor = actor || chat_session.created_by
      @on_chunk = on_chunk
      @on_message_persisted_callback = on_message_persisted
      @llm_client = llm_client
      @stream_message_id = stream_message_id
      @transport_attempt_message = chat_turn.user_message
    end

    def self.call(...)
      new(...).call
    end

    def call
      validate_session_state!

      assistant_message = run_with_fallbacks
      chat_turn.complete!(assistant_message) if assistant_message
      assistant_message
    rescue StandardError, NotImplementedError => e
      chat_turn.fail!(error: e)
      raise
    end

    # Wraps the caller-supplied callback so every message AgentLoop persists
    # during the resumed run also bumps the turn's durable checkpoint
    # (last_activity_at / write_tool_dispatched). Accepts the mixed call
    # signatures FallbackLoop/AgentLoop already use (with or without
    # `stream_message_id:`).
    def on_message_persisted
      @turn_tracking_callback ||= lambda do |message, **kwargs|
        chat_turn.record_activity!(message)
        @on_message_persisted_callback&.call(message, **kwargs)
      end
    end

    private

    def validate_session_state!
      raise ArgumentError, "Chat session is archived." if chat_session.archived?
      raise ArgumentError, "workspace chat sessions cannot be resumed" if chat_session.closed_workspace_session?
    end
  end
end
