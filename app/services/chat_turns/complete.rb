# frozen_string_literal: true

module ChatTurns
  class Complete
    def self.call(...)
      new(...).call
    end

    def initialize(turn:, assistant_message:)
      @turn = turn
      @assistant_message = assistant_message
    end

    def call
      @turn.record!("completed", status: "completed", checkpoint_message_id: @assistant_message&.id || @turn.checkpoint_message_id,
        metadata: @turn.metadata.merge("awaiting_confirmation" => @assistant_message.nil?))
    end
  end
end
