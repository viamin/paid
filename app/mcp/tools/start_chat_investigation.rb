# frozen_string_literal: true

module Tools
  # @spec QUESTION-EXPLORATION-010 QUESTION-EXPLORATION-012
  class StartChatInvestigation < BaseTool
    authorize :explore?, ->(_args) { project_for_session }, policy_class: ProjectPolicy

    def self.tool_name = "start_chat_investigation"
    def self.write_operation? = true

    def self.description
      "Start bounded research or an isolated workspace experiment for one linked question after user confirmation."
    end

    def self.available_for_chat?(user:, session:)
      session&.clarifying_question_issue.present? && exploration_enabled?(session) &&
        policy_allows?(user:, record: project_for(session), query: :explore?, policy_class: ProjectPolicy)
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          position: { type: "integer", description: "One-based linked question position" },
          kind: { type: "string", enum: ChatInvestigation::KINDS, description: "research or experiment" },
          prompt: {
            type: "string",
            description: "The bounded question to investigate; experiment prompts execute as a task in the question's isolated chat workspace and retain the output"
          },
          estimated_cost_cents: { type: "integer", minimum: 0, description: "Maximum budget reservation in cents" },
          confirmed: { type: "boolean", description: "True after the user approves this investigation" }
        },
        required: %w[position kind prompt confirmed]
      }
    end

    def perform(position:, kind:, prompt:, estimated_cost_cents: 0, confirmed: false)
      raise ArgumentError, "Question exploration is not enabled for this project" unless self.class.exploration_enabled?(session)
      raise ArgumentError, "Confirmation required: set confirmed=true to start an investigation" unless confirmed

      result = ChatInvestigations::Start.call(
        question: question_for(position), actor: user, kind:, prompt:, estimated_cost_cents:
      )
      serialize(result.investigation)
    end

    private

    def question_for(position)
      session.clarifying_question_issue.clarifying_question_progresses.find_by!(position:)
    end

    def project_for_session
      self.class.project_for(session)
    end

    def self.project_for(session)
      session.clarifying_question_issue&.project || session.project || raise(ArgumentError, "This chat has no linked project")
    end

    def self.exploration_enabled?(session)
      FeatureFlags.enabled?(:question_exploration, project: project_for(session))
    end

    def serialize(investigation)
      {
        investigation_id: investigation.id,
        question_position: investigation.clarifying_question_progress.position,
        status: investigation.status,
        authorization_required: investigation.awaiting_authorization?,
        message: investigation.metadata["authorization_required"],
        isolated_runtime: investigation.kind == "experiment"
      }.compact
    end
  end
end
