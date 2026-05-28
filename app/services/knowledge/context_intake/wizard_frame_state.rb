# frozen_string_literal: true

module Knowledge
  module ContextIntake
    class WizardFrameState
      attr_reader :session, :active_question_key, :submitted_answer_text

      def initialize(session:, active_question_key: nil, submitted_answer_text: nil)
        @session = session
        @active_question_key = active_question_key
        @submitted_answer_text = submitted_answer_text
      end

      def self.call(...)
        new(...).call
      end

      def call
        responses = session.context_intake_responses.ordered.index_by(&:question_key)
        wizard_state = WizardState.new(responses: responses, active_question_key: active_question_key)
        current_question = wizard_state.current_question
        current_response = responses[current_question[:key]]

        {
          responses: responses,
          progress: session.progress,
          wizard_state: wizard_state,
          current_question_index: wizard_state.current_question_index,
          current_question: current_question,
          current_response: current_response,
          current_answer_text: current_answer_text_for(current_response),
          previous_question: wizard_state.previous_question,
          next_question: wizard_state.next_question
        }
      end

      private

      def current_answer_text_for(current_response)
        return current_response&.answer_text if submitted_answer_text.nil?

        submitted_answer_text
      end
    end
  end
end
