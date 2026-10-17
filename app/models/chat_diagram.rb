# frozen_string_literal: true

# A constrained diagram description. Paid renders its elements; it never mounts
# generated markup or executes generated script in the application origin.
# @spec QUESTION-EXPLORATION-003 QUESTION-EXPLORATION-005 QUESTION-EXPLORATION-009
class ChatDiagram < ApplicationRecord
  SAFE_LINK = %r{\A(?:https?://|/(?!/))}i
  ELEMENT_ID = /\A[a-zA-Z][a-zA-Z0-9_-]{0,63}\z/

  belongs_to :chat_session
  belongs_to :chat_message, optional: true
  has_many :comments, class_name: "ChatDiagramComment", dependent: :destroy

  validates :question_key, :question_title, :summary, :text_equivalent, presence: true
  validate :description_is_typed

  after_create_commit :broadcast_created

  scope :current, -> { where(current: true) }

  def element(id)
    elements.find { |candidate| candidate["id"] == id }
  end

  def elements
    description.fetch("elements", [])
  end

  def relationships
    description.fetch("relationships", [])
  end

  private

  def description_is_typed
    return if !current? && description == {}
    return errors.add(:description, "must be an object") unless description.is_a?(Hash)

    validate_elements
    validate_relationships
  end

  def validate_elements
    return errors.add(:description, "must include between one and forty elements") unless elements.is_a?(Array) && elements.size.between?(1, 40)

    element_ids = elements.filter_map { |element| element["id"] if element.is_a?(Hash) }
    errors.add(:description, "contains duplicate element ids") if element_ids.uniq.size != element_ids.size
    elements.each { |element| validate_element(element) }
  end

  def validate_element(element)
    return errors.add(:description, "contains an invalid element") unless element.is_a?(Hash)
    return errors.add(:description, "contains an invalid element id") unless element["id"].is_a?(String) && ELEMENT_ID.match?(element["id"])
    return errors.add(:description, "contains an incomplete element") unless %w[label description].all? { |key| element[key].is_a?(String) && element[key].present? }
    href = element["href"]
    return if href.nil? || (href.is_a?(String) && href.blank?)

    errors.add(:description, "contains an unsafe link") unless href.is_a?(String) && SAFE_LINK.match?(href)
  end

  def validate_relationships
    return errors.add(:description, "contains invalid relationships") unless relationships.is_a?(Array)

    relationships.each do |relationship|
      return errors.add(:description, "contains an invalid relationship") unless relationship.is_a?(Hash)
      return errors.add(:description, "references an unknown element") unless [ relationship["from"], relationship["to"] ].all? { |id| element(id).present? }
    end
  end

  def broadcast_created
    ActionCable.server.broadcast("chat_session:#{chat_session_id}", {
      type: "diagram_created",
      diagram_id: id,
      question_key: question_key,
      html: ApplicationController.render(partial: "chat_diagrams/diagram", locals: { diagram: self, chat_session: })
    })
  end
end
