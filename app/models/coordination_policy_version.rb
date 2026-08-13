# frozen_string_literal: true

class CoordinationPolicyVersion < ApplicationRecord
  class InvalidTransitionError < StandardError; end

  STATUSES = %w[draft active superseded retired].freeze

  belongs_to :coordination_policy, touch: true

  validates :version, presence: true, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :coordination_policy_id }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validate :rules_is_object
  validate :parameters_is_object
  validate :metadata_is_object

  scope :active, -> { where(status: "active") }
  scope :drafts, -> { where(status: "draft") }
  scope :recent, -> { order(version: :desc, id: :desc) }

  def activate!
    coordination_policy.activate_version!(self)
  end

  def review_required?
    approval_state.fetch("required", false) == true
  end

  def review_status
    approval_state["status"]
  end

  def approved?
    review_status == "approved"
  end

  def activatable?
    !review_required? || approved?
  end

  private

  def approval_state
    metadata.to_h.fetch("evolution", {}).fetch("approval", {})
  end

  def rules_is_object
    validate_json_object(:rules)
  end

  def parameters_is_object
    validate_json_object(:parameters)
  end

  def metadata_is_object
    validate_json_object(:metadata)
  end

  def validate_json_object(attribute)
    return if public_send(attribute).is_a?(Hash)

    errors.add(attribute, "must be a JSON object")
  end
end
