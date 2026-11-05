# frozen_string_literal: true

# A bounded authorization for one delivery action on one identified work item.
# It is execution authority only: product decisions, releases, deployments,
# and project setting changes remain independently authorized.
#
# @spec BOUNDED-PHASE-AUTHORIZATION-010 @spec BOUNDED-PHASE-AUTHORIZATION-011
class BoundedDelegatedAction < ApplicationRecord
  ACTIONS = %w[review repair merge].freeze
  RESERVED_ACTIONS = %w[
    product_decision feature_approval release deployment setting_enablement
  ].freeze
  STATUSES = %w[active revoked completed].freeze

  belongs_to :account
  belongs_to :project
  belongs_to :issue
  belongs_to :created_by, class_name: "User", optional: true, inverse_of: :created_bounded_delegated_actions
  belongs_to :revoked_by, class_name: "User", optional: true, inverse_of: :revoked_bounded_delegated_actions

  validates :action, presence: true, inclusion: { in: ACTIONS, message: "is not a delegable delivery action" }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :expires_at, presence: true
  validate :evidence_is_bounded
  validate :account_matches_scope
  validate :creator_belongs_to_account
  validate :revoker_belongs_to_account

  scope :active, -> { where(status: "active").where("expires_at > ?", Time.current) }

  def allowed?
    active? && ACTIONS.include?(action)
  end

  def active?
    status == "active" && expires_at > Time.current
  end

  def revoked?
    status == "revoked"
  end

  def revoke!(user:)
    return false unless status == "active"

    update!(status: "revoked", revoked_at: Time.current, revoked_by: user)
  end

  private

  def evidence_is_bounded
    errors.add(:evidence, "must be an object") unless evidence.is_a?(Hash)
    errors.add(:evidence, "must include an intent_digest") if evidence.is_a?(Hash) && evidence["intent_digest"].blank?
    return unless evidence.is_a?(Hash)
    return if evidence["acceptance_refs"].is_a?(Array) && evidence["acceptance_refs"].any?(&:present?)

    errors.add(:evidence, "must include acceptance_refs")
  end

  def account_matches_scope
    errors.add(:account, "must match the project") if account && project && account_id != project.account_id
    errors.add(:issue, "must belong to the project") if issue && project && issue.project_id != project.id
  end

  def creator_belongs_to_account
    errors.add(:created_by, "must belong to the account") if created_by && account && created_by.account_id != account_id
  end

  def revoker_belongs_to_account
    errors.add(:revoked_by, "must belong to the account") if revoked_by && account && revoked_by.account_id != account_id
  end
end
