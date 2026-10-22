# frozen_string_literal: true

module Tools
  # @spec QUESTION-EXPLORATION-010 QUESTION-EXPLORATION-012
  class CancelChatInvestigation < BaseTool
    authorize :explore?, ->(_args) { project_for_session }, policy_class: ProjectPolicy

    def self.tool_name = "cancel_chat_investigation"
    def self.write_operation? = true

    def self.description
      "Cancel an active investigation in this question exploration chat after user confirmation."
    end

    def self.available_for_chat?(user:, session:)
      session&.clarifying_question_issue.present? && StartChatInvestigation.exploration_enabled?(session) &&
        policy_allows?(user:, record: StartChatInvestigation.project_for(session), query: :explore?, policy_class: ProjectPolicy)
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          investigation_id: { type: "integer", description: "The investigation ID in this chat" },
          confirmed: { type: "boolean", description: "True after the user approves cancellation" }
        },
        required: %w[investigation_id confirmed]
      }
    end

    def perform(investigation_id:, confirmed: false)
      raise ArgumentError, "Question exploration is not enabled for this project" unless StartChatInvestigation.exploration_enabled?(session)
      raise ArgumentError, "Confirmation required: set confirmed=true to cancel an investigation" unless confirmed

      investigation = session.chat_investigations.find(investigation_id)
      cancelled = ChatInvestigations::Cancel.call(investigation:, actor: user)
      { investigation_id: cancelled.id, status: cancelled.status, cancelled_at: cancelled.cancelled_at }
    end

    private

    def project_for_session
      StartChatInvestigation.project_for(session)
    end
  end
end
