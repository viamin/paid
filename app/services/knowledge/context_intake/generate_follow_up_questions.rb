# frozen_string_literal: true

module Knowledge
  module ContextIntake
    class GenerateFollowUpQuestions
      Result = Struct.new(:created_responses, :generated_questions, :next_question_key, keyword_init: true)

      attr_reader :session, :project, :current_question_key

      def initialize(session:, project:, current_question_key:)
        @session = session
        @project = project
        @current_question_key = current_question_key
      end

      def self.call(...)
        new(...).call
      end

      def call
        current_response = session.context_intake_responses.find_by!(question_key: current_question_key)
        current_round = QuestionnaireSchema.question_round_for_response(current_response)

        return Result.new(created_responses: [], generated_questions: [], next_question_key: nil) if attempted_rounds.include?(current_round)

        next_round = current_round + 1
        authored_questions = QuestionnaireSchema.eligible_questions(
          project: project,
          round: next_round,
          responses: session.context_intake_responses.to_a
        )
        created_responses = AppendQuestions.call(
          session: session,
          questions: authored_questions
        )

        Result.new(
          created_responses: created_responses,
          generated_questions: [],
          next_question_key: QuestionnaireSchema.ordered_responses(created_responses).first&.question_key
        )
      end

      private

      def attempted_rounds
        Array(session.metadata.to_h["follow_up_generation_attempted_rounds"]).map(&:to_i)
      end
    end
  end
end
