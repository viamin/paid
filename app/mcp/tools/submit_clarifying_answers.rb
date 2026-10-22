# frozen_string_literal: true

module Tools
  # Posts a linked chat's final clarifying answers through the standard
  # inbox answer path. Confirmation-gated like every chat write tool.
  # @spec QUESTION-EXPLORATION-002
  # @spec QUESTION-EXPLORATION-016
  class SubmitClarifyingAnswers < BaseTool
    authorize :update?, ->(_args) { project_for_session }, policy_class: ProjectPolicy

    def self.tool_name = "submit_clarifying_answers"
    def self.write_operation? = true

    def self.description
      "Post final answers for this chat's linked clarifying-questions inbox item. Use only after user confirmation."
    end

    def self.available_for_chat?(user:, session:)
      issue = session&.exploration_issue
      issue.present? && policy_allows?(user:, record: issue.project, query: :update?, policy_class: ProjectPolicy)
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          answers: {
            type: "array",
            items: { type: "string" },
            description: "Final answers in pending-question order. For a choice question: the offered option's " \
                         "text (extra rationale may follow), its number, its letter, or 'Other: <description>'"
          },
          confirmed: { type: "boolean", description: "True after the user confirms posting" }
        },
        required: %w[answers confirmed]
      }
    end

    def perform(answers:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to post clarifying answers" unless confirmed

      issue = session.exploration_issue || raise(ArgumentError, "This chat is not linked to clarifying questions")
      questions = ClarifyingQuestions::Load.call(project: issue.project, issue: issue)
      raise ArgumentError, "Answer every pending question before posting" unless answers.size == questions.size
      validate_choice_answers!(questions:, answers:)
      save_progress!(questions:, answers:)

      ClarifyingQuestions::SubmitAnswers.call(
        project: issue.project,
        issue: issue,
        questions_and_answers: questions.zip(answers).map { |question, answer| { question:, answer: } }
      )
      { posted: true, issue_id: issue.id, issue_number: issue.github_number }
    end

    private

    def validate_choice_answers!(questions:, answers:)
      questions.zip(answers).each_with_index do |(question, answer), index|
        error = ClarifyingQuestions::ChoiceAnswers.error_for(question:, answer:, position: index + 1)
        raise ArgumentError, error if error
      end
    end

    # Keep the durable chat record in sync before projecting the explicitly
    # confirmed final answer to GitHub. If GitHub rejects the submission, the
    # human's answers remain available for a later retry.
    # @spec QUESTION-EXPLORATION-002 @spec QUESTION-EXPLORATION-013
    def save_progress!(questions:, answers:)
      questions.zip(answers).each_with_index do |(_question, answer), index|
        ClarifyingQuestions::SaveProgress.call(
          chat_session: session,
          position: index + 1,
          answer:,
          actor: user
        )
      end
    end

    def project_for_session
      session.exploration_issue&.project || session.project || raise(ArgumentError, "This chat has no project")
    end
  end
end
