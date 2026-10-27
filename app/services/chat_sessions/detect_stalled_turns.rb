# frozen_string_literal: true

module ChatSessions
  class DetectStalledTurns
    DEFAULT_TIMEOUT = 5.minutes

    def self.call(timeout: configured_timeout)
      ChatTurn.stale(timeout:).find_each { |turn| new(turn, timeout:).call }
    end

    def self.configured_timeout
      ENV.fetch("CHAT_TURN_STALL_TIMEOUT_SECONDS", DEFAULT_TIMEOUT.to_i).to_i.seconds
    end
    private_class_method :configured_timeout

    def initialize(turn, timeout:)
      @turn = turn
      @timeout = timeout
    end

    def call
      @turn.with_lock do
        return unless @turn.status == "streaming" && !@turn.long_running?
        return unless @turn.last_activity_at < @timeout.ago

        @turn.update!(status: "stalled", detected_at: Time.current)
        @turn.chat_session.messages.create!(role: "system", content: notice_content, metadata: notice_metadata)
      end
    end

    private

    def notice_content
      "This turn stopped without a final response. Completed tool results remain in the transcript; any work after the last recorded activity is unknown. Review confirmations, then choose Resume to continue from the saved checkpoint."
    end

    def notice_metadata
      { "stalled_turn_notice" => true, "chat_turn_id" => @turn.id, "recovery_requires_confirmation" => true }
    end
  end
end
