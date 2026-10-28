# frozen_string_literal: true

module ChatSessions
  # An explicit user action is required before replaying a request whose model
  # stop is ambiguous. Claiming the stalled turn first makes repeated clicks
  # and concurrent browser tabs harmless.
  class RetryStalledTurn
    def initialize(turn:, actor:)
      @turn = turn
      @actor = actor
    end

    def self.call(...)
      new(...).call
    end

    # @spec CHAT-API-027
    def call
      content = claim_retry
      return false unless content

      ChatSessions::ProcessMessageJob.perform_later(
        chat_session_id: turn.chat_session_id,
        actor_id: actor.id,
        content: content,
        stream_message_id: SecureRandom.uuid
      )
      true
    end

    private

    attr_reader :turn, :actor

    def claim_retry
      turn.with_lock do
        return unless turn.stalled? && turn.user_message.present?

        turn.update!(status: "abandoned", last_activity_at: Time.current,
          metadata: turn.metadata.merge("recovery_attempted_at" => Time.current.iso8601, "recovery_outcome" => "queued"))
        turn.user_message.content
      end
    end
  end
end
