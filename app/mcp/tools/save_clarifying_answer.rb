# frozen_string_literal: true

module Tools
  # Saves a confirmed exploration answer without projecting it to GitHub.
  # @spec QUESTION-EXPLORATION-002 @spec QUESTION-EXPLORATION-013
  class SaveClarifyingAnswer < BaseTool
    authorize :update?, ->(_args) { project_for_session }, policy_class: ProjectPolicy

    def self.tool_name = "save_clarifying_answer"
    def self.write_operation? = true

    def self.description
      "Save one confirmed draft answer and its evidence context in this clarifying-questions chat. This does not post to GitHub or resolve the inbox item."
    end

    def self.available_for_chat?(user:, session:)
      issue = session&.clarifying_question_issue
      issue.present? && policy_allows?(user:, record: issue.project, query: :update?, policy_class: ProjectPolicy)
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          position: { type: "integer", description: "One-based position of the question being answered." },
          answer: { type: "string", description: "The user's confirmed draft answer." },
          evidence_context: { type: "string", description: "Optional human-readable context, such as a diagram comment or research finding." },
          design_claim: { type: "string", description: "Optional canonical design claim identifier this answer supports." },
          confirmed: { type: "boolean", description: "True only after the user confirms saving this draft." }
        },
        required: %w[position answer confirmed]
      }
    end

    def perform(position:, answer:, confirmed: false, evidence_context: nil, design_claim: nil)
      raise ArgumentError, "Confirmation required: set confirmed=true to save a clarifying answer" unless confirmed

      progress = ClarifyingQuestions::SaveProgress.call(
        chat_session: session,
        position:,
        answer:,
        actor: user,
        evidence_context:,
        design_claim:
      )
      { posted: false, position: progress.position, question: progress.question }
    end

    private

    def project_for_session
      session.clarifying_question_issue&.project || raise(ArgumentError, "This chat is not linked to clarifying questions")
    end
  end
end
