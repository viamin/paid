# frozen_string_literal: true

module ChatDiagrams
  # JSON transport representation. The description remains data, never HTML.
  # Human comments travel with the diagram so every transport carries the same
  # discussion context, including a superseded diagram's own comments.
  # @spec QUESTION-EXPLORATION-003 QUESTION-EXPLORATION-004
  # @spec QUESTION-EXPLORATION-009 QUESTION-EXPLORATION-012
  class Serializer
    COMMENT_LIMIT = ChatDiagramComment::CONTEXT_LIMIT

    def self.call(diagram)
      return unless diagram

      { id: diagram.id, question_key: diagram.question_key, question_title: diagram.question_title,
        summary: diagram.summary, text_equivalent: diagram.text_equivalent, description: diagram.description,
        current: diagram.current?, comments: comments(diagram) }
    end

    # @spec QUESTION-EXPLORATION-004
    def self.comments(diagram)
      diagram.comments.last(COMMENT_LIMIT).map { |comment| CommentSerializer.call(comment) }
    end
    private_class_method :comments
  end
end
