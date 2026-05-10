# frozen_string_literal: true

class CoordinationPolicyVersion < ApplicationRecord
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

  private

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
