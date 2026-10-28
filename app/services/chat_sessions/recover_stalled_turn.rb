# frozen_string_literal: true

module ChatSessions
  # Records an explicit recovery decision without replaying an unknown model
  # request. A later checkpoint-aware implementation can add a safe replay
  # branch here; the lock already prevents concurrent recovery decisions.
  class RecoverStalledTurn
    def self.call(...) = new(...).call

    def initialize(turn:, actor:)
      @turn = turn
      @actor = actor
    end

    def call
      turn.with_lock do
        return turn unless turn.status == "stalled"

        turn.update!(status: "abandoned", recovery_attempts: turn.recovery_attempts + 1, last_activity_at: Time.current)
        turn.chat_session.messages.create!(
          role: "system",
          content: "Recovery was requested. The incomplete turn was not replayed, so completed tool activity cannot run twice. Send a new message to continue from the preserved transcript.",
          metadata: { "stalled_turn_recovery" => true, "chat_turn_id" => turn.id, "actor_id" => actor.id }
        )
        Rails.logger.info(message: "chat_turn.recovery_requested", chat_turn_id: turn.id, chat_session_id: turn.chat_session_id,
          actor_user_id: actor.id, side_effecting_tools_completed: turn.side_effecting_tools_completed?)
        turn
      end
    end

    private

    attr_reader :turn, :actor
  end
end
