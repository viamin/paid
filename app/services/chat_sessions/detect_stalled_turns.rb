# frozen_string_literal: true

module ChatSessions
  class DetectStalledTurns
    DEFAULT_THRESHOLD = 15.minutes

    def self.call(...)
      new(...).call
    end

    def initialize(now: Time.current, threshold: configured_threshold)
      @now = now
      @threshold = threshold
    end

    def call
      ChatTurn.stall_candidates(now - threshold).find_each { |turn| classify(turn) }
    end

    private

    attr_reader :now, :threshold

    def configured_threshold
      configured = ENV.fetch("CHAT_TURN_STALL_THRESHOLD_SECONDS", DEFAULT_THRESHOLD.to_i).to_i.seconds
      configured.positive? ? configured : DEFAULT_THRESHOLD
    end

    def classify(turn)
      turn.with_lock do
        return unless turn.stallable_at?(now, threshold:)

        turn.update!(state: "stalled", stalled_at: now)
        turn.record!("stalled", detected_at: now.iso8601, side_effecting_tools_completed: side_effecting_tools_completed?(turn))
        persist_notice(turn)
      end
    end

    def side_effecting_tools_completed?(turn)
      turn.chat_session.messages.where.not(tool_status: [ nil, "pending" ]).exists?
    end

    def persist_notice(turn)
      built = StalledTurnNotice.build(turn:)
      turn.chat_session.messages.create!(role: "system", content: built.content, metadata: built.metadata)
    end
  end
end
