# frozen_string_literal: true

module Knowledge
  module ContextIntake
    class GenerateFollowUpQuestions
      Result = Struct.new(:created_responses, :generated_questions, :next_question_key, keyword_init: true)

      attr_reader :session, :project, :current_question_key, :auto_approve, :generate_with_agent

      def initialize(session:, project:, current_question_key:, auto_approve: true, generate_with_agent: false)
        @session = session
        @project = project
        @current_question_key = current_question_key
        @auto_approve = auto_approve
        @generate_with_agent = generate_with_agent
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
        generated_questions = if generate_with_agent
          GenerateQuestions.call(
            project: project,
            session: session,
            round: next_round,
            auto_approve: auto_approve
          )
        else
          []
        end
        created_responses = AppendQuestions.call(
          session: session,
          questions: authored_questions + generated_questions.select(&:approved?).map(&:to_question_hash)
        )

        mark_round_attempted!(current_round)

        Result.new(
          created_responses: created_responses,
          generated_questions: generated_questions,
          next_question_key: QuestionnaireSchema.ordered_responses(created_responses).first&.question_key
        )
      end

      private

      def attempted_rounds
        Array(session.metadata.to_h["follow_up_generation_attempted_rounds"]).map(&:to_i)
      end

      def mark_round_attempted!(round)
        session.update!(
          metadata: session.metadata.to_h.merge(
            "follow_up_generation_attempted_rounds" => (attempted_rounds + [ round ]).uniq.sort
          )
        )
      end
    end
  end
end
