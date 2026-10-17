# frozen_string_literal: true

# @spec QUESTION-EXPLORATION-004 QUESTION-EXPLORATION-005 QUESTION-EXPLORATION-006
class ChatDiagramComment < ApplicationRecord
  belongs_to :chat_diagram
  belongs_to :actor, class_name: "User"

  validates :question_key, presence: true
  validates :body, presence: true, length: { maximum: 12_000 }
  validate :selected_element_has_context

  private

  def selected_element_has_context
    return if element_id.blank? && element_context.blank?
    return if element_id.present? && element_context.present?

    errors.add(:base, "selected element requires its textual context")
  end
end
