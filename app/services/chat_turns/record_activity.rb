# frozen_string_literal: true

module ChatTurns
  class RecordActivity
    def self.call(...)
      new(...).call
    end

    def initialize(turn:)
      @turn = turn
    end

    def call
      @turn.update!(last_activity_at: Time.current) if @turn.status.in?(ChatTurn::ACTIVE_STATUSES)
      @turn
    end
  end
end
