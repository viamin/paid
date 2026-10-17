# frozen_string_literal: true

module ChatDiagrams
  # JSON transport representation. The description remains data, never HTML.
  # @spec QUESTION-EXPLORATION-003 QUESTION-EXPLORATION-009 QUESTION-EXPLORATION-012
  class Serializer
    def self.call(diagram)
      return unless diagram

      { id: diagram.id, question_key: diagram.question_key, question_title: diagram.question_title,
        summary: diagram.summary, text_equivalent: diagram.text_equivalent, description: diagram.description,
        current: diagram.current? }
    end
  end
end
