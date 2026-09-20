# frozen_string_literal: true

# Immutable, provider-neutral description of an Apple verification guest.
# @spec APPLE-WORKER-001
class AppleWorkerProfile < ApplicationRecord
  include SecretSafeMetadata

  STATUSES = %w[active deprecated revoked].freeze

  belongs_to :account
  belongs_to :created_by, class_name: "User", optional: true
  has_many :apple_verification_workflow_revisions, dependent: :restrict_with_exception
  has_many :apple_verification_attempts, dependent: :restrict_with_exception

  validates :name, :image_digest, presence: true
  validates :image_digest, format: { with: /\Asha256:[a-f0-9]{64}\z/ }
  validates :status, inclusion: { in: STATUSES }
  validate :creator_matches_account
  validate :capabilities_are_safe
  validate :constraints_are_safe
  validate :supported_profile_contract
  validate :immutable_contract, on: :update

  def active?
    status == "active"
  end

  def revoked?
    status == "revoked"
  end

  private

  def creator_matches_account
    return unless created_by && created_by.account_id != account_id

    errors.add(:created_by, "must belong to the profile account")
  end

  def capabilities_are_safe
    validate_safe_object(capabilities, :capabilities)
  end

  def constraints_are_safe
    validate_safe_object(constraints, :constraints)
  end

  def supported_profile_contract
    return unless capabilities.is_a?(Hash) && constraints.is_a?(Hash)

    AppleVerificationWorkers::ProfileConstraints.new(
      platforms: constraints["platforms"],
      xcode_version: constraints["xcode_version"],
      simulator_runtimes: constraints["simulator_runtimes"],
      capabilities: capabilities["capabilities"]
    )
  rescue AppleVerificationWorkers::UnsupportedCapability, ArgumentError => error
    errors.add(:base, error.message)
  end

  def validate_safe_object(value, attribute)
    errors.add(attribute, "must be an object") unless value.is_a?(Hash)
    scan_metadata_for_secrets(value, attribute:) if value.is_a?(Hash)
  end

  def immutable_contract
    return unless will_save_change_to_name? || will_save_change_to_image_digest? || will_save_change_to_capabilities? || will_save_change_to_constraints?

    errors.add(:base, "worker profile constraints are immutable")
  end
end
