# frozen_string_literal: true

module ChatTurns
  class DetectStalled
    # @spec CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-003
    def self.call(turn:, detected_at: Time.current)
      new(turn:, detected_at:).call
    end

    def initialize(turn:, detected_at:)
      @turn = turn
      @detected_at = detected_at
    end

    def call
      turn.with_lock do
        turn.reload
        return false unless eligible?

        turn.update!(state: "stalled", detected_stalled_at: detected_at,
          failure_classification: "ambiguous_stop", pause_reason: nil)
        persist_notice!
      end
      log_detection
      true
    end

    private

    attr_reader :turn, :detected_at

    def eligible?
      turn.state.in?(%w[pending streaming]) &&
        (turn.lease_expires_at.nil? || turn.lease_expires_at <= detected_at) &&
        !turn.awaiting_confirmation?
    end

    def persist_notice!
      return if turn.chat_session.messages.where("metadata ->> 'chat_turn_id' = ?", turn.id.to_s)
        .where("metadata ->> 'chat_turn_stalled_notice' = 'true'").exists?

      turn.chat_session.messages.create!(role: "system", content: notice_content, metadata: notice_metadata)
    end

    def notice_content
      checkpoint = turn.last_checkpoint_message_id ? "message ##{turn.last_checkpoint_message_id}" : "the saved request"
      side_effects = turn.side_effects_completed? ? "A side-effecting tool completed before the stop." : "No completed side-effecting tool was recorded."
      "This turn stopped after #{checkpoint}; the remaining work is unknown. #{side_effects} " \
        "Review the preserved tool activity, then use Resume to continue from the durable checkpoint."
    end

    def notice_metadata
      {
        "chat_turn_stalled_notice" => true,
        "chat_turn_id" => turn.id,
        "turn_revision" => turn.revision,
        "last_checkpoint_message_id" => turn.last_checkpoint_message_id,
        "side_effects_completed" => turn.side_effects_completed?
      }
    end

    def log_detection
      Rails.logger.warn(message: "chat_turn.stalled", chat_turn_id: turn.id,
        chat_session_id: turn.chat_session_id, detected_at: detected_at,
        side_effects_completed: turn.side_effects_completed?)
    end
  end
end
