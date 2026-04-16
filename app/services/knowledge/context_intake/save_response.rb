# frozen_string_literal: true

module Knowledge
  module ContextIntake
    # Saves an answer for a specific question in a context intake session.
    class SaveResponse
      attr_reader :session, :question_key, :answer_text, :skipped

      def initialize(session:, question_key:, answer_text: nil, skipped: false)
        @session = session
        @question_key = question_key
        @answer_text = answer_text
        @skipped = skipped
      end

      def self.call(...)
        new(...).call
      end

      def call
        validate_skip_allowed! if skipped
        response = session.context_intake_responses.find_by!(question_key: question_key)

        ActiveRecord::Base.transaction do
          response.update!(
            answer_text: skipped ? nil : answer_text,
            skipped: skipped,
            provenance: "human"
          )

          update_session_step!
        end

        response
      end

      private

      def validate_skip_allowed!
        question = QuestionnaireSchema.find_question(question_key)
        return unless question&.dig(:question, :required)

        raise ArgumentError, "Cannot skip required question: #{question_key}"
      end

      def update_session_step!
        answered_count = session.context_intake_responses
                                .where(is_follow_up: false)
                                .answered
                                .count
        session.update!(current_step: answered_count)
      end
    end
  end
end
