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
        response = session.context_intake_responses.find_by!(question_key: question_key)
        validate_skip_allowed!(response) if skipped

        ActiveRecord::Base.transaction do
          response.update!(
            answer_text: skipped ? nil : normalized_answer_text,
            skipped: skipped,
            provenance: "human"
          )

          update_session_step!
        end

        response
      end

      private

      def validate_skip_allowed!(response)
        return unless QuestionnaireSchema.required_question_for_response?(response)

        raise ArgumentError, "Cannot skip required question: #{question_key}"
      end

      def update_session_step!
        answered_count = session.context_intake_responses.answered.count
        session.update!(current_step: answered_count)
      end

      def normalized_answer_text
        return if answer_text.to_s.strip.empty?

        answer_text
      end
    end
  end
end
