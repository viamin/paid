# frozen_string_literal: true

module Tools
  # Posts a linked chat's final clarifying answers through the standard
  # inbox answer path. Confirmation-gated like every chat write tool.
  # @spec QUESTION-EXPLORATION-002
  class SubmitClarifyingAnswers < BaseTool
    authorize :update?, ->(_args) { project_for_session }, policy_class: ProjectPolicy

    def self.tool_name = "submit_clarifying_answers"
    def self.write_operation? = true

    def self.description
      "Post final answers for this chat's linked clarifying-questions inbox item. Use only after user confirmation."
    end

    def self.available_for_chat?(user:, session:)
      session&.clarifying_question_issue.present? && policy_allows?(user:, record: session.project, query: :update?, policy_class: ProjectPolicy)
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          answers: { type: "array", items: { type: "string" }, description: "Final answers in pending-question order" },
          confirmed: { type: "boolean", description: "True after the user confirms posting" }
        },
        required: %w[answers confirmed]
      }
    end

    def perform(answers:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to post clarifying answers" unless confirmed

      issue = session.clarifying_question_issue || raise(ArgumentError, "This chat is not linked to clarifying questions")
      questions = ClarifyingQuestions::Load.call(project: issue.project, issue: issue)
      raise ArgumentError, "Answer every pending question before posting" unless answers.size == questions.size

      ClarifyingQuestions::SubmitAnswers.call(
        project: issue.project,
        issue: issue,
        questions_and_answers: questions.zip(answers).map { |question, answer| { question:, answer: } }
      )
      { posted: true, issue_id: issue.id, issue_number: issue.github_number }
    end

    private

    def project_for_session
      session.project || session.clarifying_question_issue&.project || raise(ArgumentError, "This chat has no project")
    end
  end
end
