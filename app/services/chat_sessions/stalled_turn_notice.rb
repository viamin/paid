# frozen_string_literal: true

module ChatSessions
  class StalledTurnNotice
    Result = Data.define(:content, :metadata)

    def self.build(turn:)
      new(turn:).build
    end

    def initialize(turn:)
      @turn = turn
    end

    def build
      Result.new(content:, metadata:)
    end

    private

    attr_reader :turn

    def content
      "This chat turn stopped making durable progress and needs attention. " \
        "Any messages and tool results already shown above were preserved; the remaining response is unknown. " \
        "Review completed tool activity before explicitly retrying this request."
    end

    def metadata
      { "stalled_turn_notice" => true, "chat_turn_id" => turn.id, "recovery" => "explicit_confirmation_required" }
    end
  end
end
