# frozen_string_literal: true

module ChatTurns
  class Lifecycle
    STALL_TIMEOUT = 10.minutes
    def self.start!(chat_session:, user_message:, stream_message_id:)
      chat_session.chat_turns.find_or_create_by!(stream_message_id:) do |turn|
        turn.user_message = user_message
        turn.status = "streaming"
        turn.last_activity_at = Time.current
      end
    end
    def self.activity!(turn) = turn.update!(last_activity_at: Time.current) unless turn.terminal?
    def self.complete!(turn, status:, classification: nil)
      turn.update!(status:, failure_classification: classification, terminal_at: Time.current, last_activity_at: Time.current)
    end
    def self.fail!(turn, error) = complete!(turn, status: "failed", classification: error.class.name)
  end
end
