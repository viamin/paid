# frozen_string_literal: true

module Knowledge
  module ContextIntake
    class WizardState
      attr_reader :responses, :active_question_key

      def initialize(responses:, active_question_key: nil)
        @responses = responses || {}
        @active_question_key = active_question_key
      end

      def ordered_questions
        @ordered_questions ||= QuestionnaireSchema.sections.flat_map do |section|
          section[:questions].map do |question|
            question.merge(section_key: section[:key], section_title: section[:title])
          end
        end
      end

      def current_question_index
        @current_question_index ||= begin
          requested_question_index = ordered_questions.index { |question| question[:key] == active_question_key }
          requested_question_index || next_incomplete_question_index || 0
        end
      end

      def current_question
        ordered_questions.fetch(current_question_index)
      end

      def total_questions
        ordered_questions.length
      end

      def current_question_number
        current_question_index + 1
      end

      def previous_question
        return if current_question_index.zero?

        ordered_questions[current_question_index - 1]
      end

      def next_question
        ordered_questions[current_question_index + 1]
      end

      def first_question?
        current_question_index.zero?
      end

      def last_question?
        current_question_index == total_questions - 1
      end

      def navigation_question_key(current_question_key:, direction:)
        offset = direction == "previous" ? -1 : 1
        current_index = ordered_questions.index { |question| question[:key] == current_question_key } || 0
        target_index = (current_index + offset).clamp(0, total_questions - 1)

        ordered_questions.fetch(target_index).fetch(:key)
      end

      def first_unanswered_required_question_key
        required_keys = QuestionnaireSchema.required_questions.map { |question| question[:key] }

        ordered_questions.find do |question|
          required_keys.include?(question[:key]) && !responses[question[:key]]&.answered?
        end&.fetch(:key, active_question_key)
      end

      private

      def next_incomplete_question_index
        ordered_questions.index do |question|
          !responses[question[:key]]&.answered?
        end
      end
    end
  end
end
