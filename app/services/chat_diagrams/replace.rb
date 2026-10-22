# frozen_string_literal: true

module ChatDiagrams
  # Keeps one reconnectable diagram per question while releasing superseded
  # visual source. Comments already contain their durable textual context.
  # @spec QUESTION-EXPLORATION-005
  class Replace
    def self.call(...) = new(...).call

    def initialize(chat_session:, question_key:, question_title:, summary:, text_equivalent:, description:, chat_message: nil)
      @chat_session = chat_session
      @attributes = { question_key:, question_title:, summary:, text_equivalent:, description:, chat_message: }
    end

    def call
      ChatDiagram.transaction do
        retire_current_diagram
        chat_session.chat_diagrams.create!(@attributes)
      end
    end

    private

    attr_reader :chat_session

    def retire_current_diagram
      chat_session.chat_diagrams.current.where(question_key: @attributes[:question_key]).lock.each do |diagram|
        diagram.update!(current: false, description: {})
      end
    end
  end
end
