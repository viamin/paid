# frozen_string_literal: true

module ChatTurns
  class Fail
    def self.call(...)
      new(...).call
    end

    def initialize(turn:, error:)
      @turn = turn
      @error = error
    end

    def call
      @turn.record!("failed", status: "failed", classification: @error.class.name.underscore,
        metadata: @turn.metadata.merge("error_class" => @error.class.name))
    end
  end
end
