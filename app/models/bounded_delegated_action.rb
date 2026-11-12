# frozen_string_literal: true

# A bounded authorization for one delivery action on one identified work item.
# It is execution authority only: product decisions, releases, deployments,
# and project setting changes remain independently authorized.
#
# @spec BOUNDED-PHASE-AUTHORIZATION-004 @spec BOUNDED-PHASE-AUTHORIZATION-005
# @spec BOUNDED-PHASE-AUTHORIZATION-009 @spec BOUNDED-PHASE-AUTHORIZATION-010
# @spec BOUNDED-PHASE-AUTHORIZATION-011 @spec PROJECT-DELEGATION-006
class BoundedDelegatedAction < ApplicationRecord
  ACTIONS = %w[review repair merge].freeze
  RESERVED_ACTIONS = %w[
    product_decision feature_approval release deployment setting_enablement
  ].freeze
  STATUSES = %w[active held reassessment_required revoked expired stopped completed].freeze
  INTENT_DIGEST_FORMAT = /\Asha256:[a-f0-9]{64}\z/

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

  def held? = status == "held"
  def reassessment_required? = status == "reassessment_required"
  def expired? = status == "expired"
  def stopped? = status == "stopped"
  def completed? = status == "completed"

  def revoked?
    status == "revoked"
  end

  # Lifecycle write only: caller surfaces reach this through
  # Automation::RevokeBoundedAction, which enforces the action-specific
  # project policy before revocation. The model still fails closed on
  # cross-account revokers via revoker_belongs_to_account.
  def revoke!(user:)
    transition!(status: "revoked", reason: "authorization_revoked", actor: user,
      audit_action: "bounded_action.revoked", extra_attrs: { revoked_at: Time.current, revoked_by: user })
  end

  def hold!(reason:, evidence: {}, actor: nil)
    transition!(status: "held", reason:, evidence:, actor:, audit_action: "bounded_action.held")
  end

  def require_reassessment!(reason:, evidence: {}, actor: nil)
    transition!(status: "reassessment_required", reason:, evidence:, actor:,
      audit_action: "bounded_action.reassessment_required")
  end

  def expire_if_needed!(actor: nil, now: Time.current)
    return false unless status == "active" && expires_at <= now

    transition!(status: "expired", reason: "authorization_expired", actor:, audit_action: "bounded_action.expired")
  end

  def bounded_stop!(evidence:, actor: nil)
    transition!(status: "stopped", reason: "bounded_phase_stop", evidence:, actor:,
      audit_action: "bounded_action.stopped")
  end

  private

  def evidence_is_bounded
    errors.add(:evidence, "must be an object") unless evidence.is_a?(Hash)
    return unless evidence.is_a?(Hash)

    validate_intent_digest
    return if evidence["acceptance_refs"].is_a?(Array) && evidence["acceptance_refs"].any?(&:present?)

    errors.add(:evidence, "must include acceptance_refs")
  end

  def validate_intent_digest
    digest = evidence["intent_digest"]
    return if digest.is_a?(String) && digest.match?(INTENT_DIGEST_FORMAT)

    if digest.blank?
      errors.add(:evidence, "must include an intent_digest")
    else
      errors.add(:evidence, "intent_digest must be a sha256:<64 hex characters> digest")
    end
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

  def transition!(status:, reason:, evidence: {}, actor:, audit_action:, extra_attrs: {})
    with_lock do
      return false unless self.status == "active"

      lifecycle_evidence = { "reason" => reason }.merge(self.lifecycle_evidence.to_h.stringify_keys)
        .merge(evidence.to_h.stringify_keys)
      update!(status:, status_reason: reason, lifecycle_evidence:, lifecycle_changed_at: Time.current, **extra_attrs)
      Audit::RecordEvent.call(
        action: audit_action,
        actor:,
        subject: self,
        metadata: { "action" => action, "reason" => reason, "lifecycle_evidence" => lifecycle_evidence }
      )
    end
    true
  end
end
