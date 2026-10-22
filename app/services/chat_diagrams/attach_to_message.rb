# frozen_string_literal: true

module ChatDiagrams
  # Connects a diagram created by the presentation tool to its durable tool
  # result, making the diagram available when the transcript is reloaded.
  # @spec QUESTION-EXPLORATION-003 QUESTION-EXPLORATION-012
  class AttachToMessage
    def self.call(message:) = new(message:).call

    def initialize(message:)
      @message = message
    end

    def call
      return unless message.tool_name == Tools::PresentChatDiagram.tool_name

      diagram = message.chat_session.chat_diagrams.find_by(id: diagram_id)
      diagram&.update!(chat_message: message)
    end

    private

    attr_reader :message

    def diagram_id
      diagram = message.tool_result&.fetch("diagram", nil) || message.tool_result&.fetch(:diagram, nil)
      diagram&.fetch("id", nil) || diagram&.fetch(:id, nil)
    end
  end
end
