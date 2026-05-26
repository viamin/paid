# frozen_string_literal: true

module Knowledge
  module ContextIntake
    class AppendQuestions
      attr_reader :session, :questions

      def initialize(session:, questions:)
        @session = session
        @questions = Array(questions)
      end

      def self.call(...)
        new(...).call
      end

      def call
        questions.filter_map do |question|
          next if session.context_intake_responses.exists?(question_key: question[:key])

          session.context_intake_responses.create!(
            question_key: question[:key],
            question_text: question[:text],
            section: question[:section_key],
            sequence: round_scoped_sequence(question),
            is_follow_up: question[:is_follow_up] == true,
            parent_response: parent_response_for(question[:parent_question_key]),
            skipped: false,
            provenance: question[:provenance] || "human",
            answer_data: { "question" => QuestionnaireSchema.question_snapshot(question) }
          )
        end
      end

      private

      # Encode round into sequence so follow-up questions in the same section
      # always sort after earlier-round questions when using the `ordered` scope.
      def round_scoped_sequence(question)
        round = (question[:round] || 1).to_i
        display_order = (question[:display_order] || 0).to_i
        ((round - 1) * 1000) + display_order
      end

      def parent_response_for(parent_question_key)
        return if parent_question_key.blank?

        session.context_intake_responses.find_by(question_key: parent_question_key)
      end
    end
  end
end
