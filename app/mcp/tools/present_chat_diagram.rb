# frozen_string_literal: true

module Tools
  # Lets the chat agent offer a typed visual without treating that offer as a
  # decision, preference, or confidence update.
  # @spec QUESTION-EXPLORATION-003 QUESTION-EXPLORATION-009 QUESTION-EXPLORATION-011
  class PresentChatDiagram < BaseTool
    authorize :create?, ->(_args) { ChatMessage.new(chat_session: session) }, policy_class: ChatMessagePolicy

    def self.tool_name = "present_chat_diagram"

    # Persists ChatDiagram rows and broadcasts rendered HTML into the live chat.
    # Declaring this mutation keeps the RDR-028 confirmation gate and excludes
    # it from MCP's read-only-by-default surface.
    def self.write_operation? = true

    def self.description
      "Present a validated, temporary diagram for a question. Use only when a diagram helps explain the question."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          question_key: { type: "string" }, question_title: { type: "string" }, summary: { type: "string" },
          text_equivalent: { type: "string" }, description: { type: "object" }
        },
        required: %w[question_key question_title summary text_equivalent description]
      }
    end

    def perform(question_key:, question_title:, summary:, text_equivalent:, description:)
      diagram = ChatDiagrams::Replace.call(chat_session: session, question_key:, question_title:, summary:, text_equivalent:, description:)
      { diagram: ChatDiagrams::Serializer.call(diagram) }
    end
  end
end
