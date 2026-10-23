# frozen_string_literal: true

module ChatDiagrams
  # One representation of a human diagram comment for every transport. The
  # comment carries the element text it was made against, so it stays
  # intelligible after the diagram it referenced is replaced or released.
  # @spec QUESTION-EXPLORATION-004 QUESTION-EXPLORATION-006 QUESTION-EXPLORATION-012
  class CommentSerializer
    def self.call(comment)
      return unless comment

      { id: comment.id, actor_id: comment.actor_id, question_key: comment.question_key, body: comment.body,
        element_id: comment.element_id, element_context: comment.element_context, created_at: comment.created_at }
    end
  end
end
