# frozen_string_literal: true

module ChatTurns
  class RecordActivity
    def self.call(...)
      new(...).call
    end

    def initialize(turn:, message: nil)
      @turn = turn
      @message = message
    end

    def call
      @turn.record!("activity", checkpoint_message_id: @message&.id || @turn.checkpoint_message_id)
    end
  end
end
