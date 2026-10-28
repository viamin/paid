# frozen_string_literal: true

module ChatTurns
  class Complete
    def self.call(...)
      new(...).call
    end

    def initialize(turn:, paused_for_confirmation: false)
      @turn = turn
      @paused_for_confirmation = paused_for_confirmation
    end

    def call
      @turn.update!(status: "completed", completed_at: Time.current, last_activity_at: Time.current,
        metadata: @turn.metadata.merge("terminal_reason" => (@paused_for_confirmation ? "awaiting_confirmation" : "response_persisted")))
      @turn
    end
  end
end
