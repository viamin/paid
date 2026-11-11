# frozen_string_literal: true

# Account trusted-team/user defaults with project-level additions/overrides.
# This is an additional admission path for non-GitHub providers; it does not
# replace or widen the existing GitHub allowlist/`issue.trusted?` gate.
#
# @spec UNIFIED-WORK-ITEMS-004
class TrustedProviderIdentity < ApplicationRecord
  IDENTITY_TYPES = %w[team user].freeze

  belongs_to :account
  belongs_to :project, optional: true
  belongs_to :created_by, class_name: "User", optional: true

  validates :provider, :external_id, presence: true
  validates :identity_type, inclusion: { in: IDENTITY_TYPES }
  validate :project_belongs_to_same_account

  scope :account_defaults, -> { where(project_id: nil) }
  scope :for_project, ->(project) { where(project_id: [ nil, project.id ]) }

  def account_default? = project_id.nil?

  private

  def project_belongs_to_same_account
    return if project.nil? || project.account_id == account_id

    errors.add(:project, "must belong to the same account")
  end
end
