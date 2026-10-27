# frozen_string_literal: true

module ChatSessions
  # Explicit recovery starts a fresh model request from the durable transcript.
  # It never re-dispatches a stored tool call; any newly proposed write still
  # passes through the normal confirmation gate.
  class ResumeTurn
    attr_reader :chat_session, :actor, :llm_client, :on_chunk, :on_message_persisted, :stream_message_id,
      :transport_attempt_message

    def initialize(chat_turn:, actor:, on_chunk: nil, on_message_persisted: nil, llm_client: nil, stream_message_id: nil)
      @chat_turn = chat_turn
      @chat_session = chat_turn.chat_session
      @actor = actor
      @on_chunk = on_chunk
      @on_message_persisted = on_message_persisted
      @llm_client = llm_client
      @stream_message_id = stream_message_id
      @transport_attempt_message = chat_turn.user_message
    end

    def self.call(...)
      new(...).call
    end

    # @spec CHAT-TURN-004
    def call
      ChatSessions::AgentLoop.new(
        chat_session:,
        actor:,
        llm_client: build_llm_client,
        on_chunk:,
        on_message_persisted:,
        stream_message_id:,
        chat_turn: @chat_turn
      ).run
    end

    private

    def build_llm_client
      llm_client || ChatSessions::BuildLlmClient.call(chat_session:, actor:, message: transport_attempt_message)
    end
  end
end
