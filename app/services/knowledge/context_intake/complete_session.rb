# frozen_string_literal: true

module Knowledge
  module ContextIntake
    # Validates that required questions are answered and marks the session complete.
    # Triggers synthesis of answers into knowledge artifacts.
    class CompleteSession
      attr_reader :session

      def initialize(session:)
        @session = session
      end

      def self.call(...)
        new(...).call
      end

      def call
        ActiveRecord::Base.transaction do
          validate_required_questions!
          session.complete!
          synthesize_knowledge!
        end
        session
      end

      private

      def validate_required_questions!
        catalog_index = Knowledge::ContextIntake::QuestionnaireSchema.question_catalog_index(project: session.project)
        unanswered = session.context_intake_responses.select do |response|
          QuestionnaireSchema.required_question_for_response?(response, catalog_index: catalog_index) && response.answer_text.blank?
        end

        return if unanswered.empty?

        keys = unanswered.map(&:question_key).join(", ")
        raise ActiveRecord::RecordInvalid.new(session),
          "Required questions not answered: #{keys}"
      end

      def synthesize_knowledge!
        Synthesize.call(session: session)
      end
    end
  end
end
