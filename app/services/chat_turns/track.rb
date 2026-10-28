# frozen_string_literal: true

module ChatTurns
  class Track
    def self.start!(chat_session:, user_message:, actor:, stream_message_id:)
      turn = ChatTurn.find_or_initialize_by(user_message:)
      turn.assign_attributes(
        account: chat_session.account,
        chat_session:,
        actor:,
        stream_message_id: stream_message_id.presence || turn.stream_message_id,
        status: "streaming",
        last_activity_at: Time.current,
        failure_classification: nil
      )
      turn.save!
      turn
    end

    def self.activity!(turn)
      turn.update!(last_activity_at: Time.current) unless turn.status.in?(%w[completed failed abandoned])
    end

    def self.complete!(turn)
      turn.update!(status: "completed", completed_at: Time.current, last_activity_at: Time.current)
    end

    def self.fail!(turn, classification:)
      turn.update!(status: "failed", failure_classification: classification, last_activity_at: Time.current)
    end
  end
end
