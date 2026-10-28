# frozen_string_literal: true

module ChatTurns
  class Fail
    def self.call(...)
      new(...).call
    end

    def initialize(chat_turn:, classification:, message:)
      @chat_turn = chat_turn
      @classification = classification
      @message = message
    end

    def call
      return unless chat_turn.fail!(classification)

      chat_turn.chat_session.messages.create!(role: "system", content: message, metadata: notice_metadata)
    end

    private

    attr_reader :chat_turn, :classification, :message

    def notice_metadata
      { "chat_turn_failure_notice" => true, "chat_turn_id" => chat_turn.id, "classification" => classification }
    end
  end
end
