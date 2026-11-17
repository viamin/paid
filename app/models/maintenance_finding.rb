# frozen_string_literal: true

# Project- and recipe-scoped recurring maintenance finding identity.
# @spec MAINT-026 MAINT-028 MAINT-029
class MaintenanceFinding < ApplicationRecord
  STATUSES = %w[open dismissed repaired].freeze

  belongs_to :account
  belongs_to :project
  has_many :occurrences, class_name: "MaintenanceFindingOccurrence", dependent: :restrict_with_exception

  validates :category, :claim, :identity_digest, :recipe_key, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :identity_digest, uniqueness: { scope: %i[project_id recipe_key] }
  validate :dismissal_has_reason
  validate :tenant_matches_project

  def dismiss!(reason:)
    update!(status: "dismissed", dismissal_reason: reason.to_s.strip, reassessment_required: false)
  end

  def dismissed? = status == "dismissed"

  private

  def dismissal_has_reason
    return unless status == "dismissed" && dismissal_reason.blank?

    errors.add(:dismissal_reason, "is required when dismissing a finding")
  end

  def tenant_matches_project
    return if account.blank? || project.blank? || account_id == project.account_id

    errors.add(:account, "must match the project")
  end
end
