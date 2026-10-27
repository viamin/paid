# frozen_string_literal: true

module ChatTurns
  class Track
    def self.start!(chat_session:, user_message:, stream_message_id: nil)
      turn = chat_session.chat_turns.create!(user_message:, stream_message_id:, status: "streaming", last_activity_at: Time.current)
      record_event(turn, "created")
      turn
    end

    def self.activity!(turn, message: nil)
      message.update_column(:chat_turn_id, turn.id) if message && message.chat_turn_id != turn.id
      turn.update!(last_activity_at: Time.current)
      record_event(turn, "activity", message_id: message&.id)
    end

    def self.completed!(turn, awaiting_confirmation: false)
      status = awaiting_confirmation ? "awaiting_confirmation" : "completed"
      turn.update!(status:, completed_at: awaiting_confirmation ? nil : Time.current, last_activity_at: Time.current)
      record_event(turn, "completed", status:)
    end

    def self.failed!(turn, error:)
      turn.update!(status: "failed", failure_classification: error.class.name, last_activity_at: Time.current)
      record_event(turn, "failed", error_class: error.class.name)
    end

    def self.record_event(turn, event_type, metadata = {})
      turn.events.create!(event_type:, metadata:, occurred_at: Time.current)
    end
  end
end
