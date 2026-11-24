# frozen_string_literal: true

# A bounded authorization for one delivery action on one identified work item.
# It is execution authority only: product decisions, releases, deployments,
# and project setting changes remain independently authorized.
#
# The authorization pins its same-work lineage (the root work item and the
# pull requests linked to it, as established by the continuation lookup at
# admission). Work outside that lineage — another issue, a decomposed child,
# an unrelated or later-linked pull request — needs its own explicit
# authorization; no GitHub approval, mention, dependency, parent/child
# relation, or milestone membership extends the pinned lineage.
#
# @spec BOUNDED-PHASE-AUTHORIZATION-001
# @spec BOUNDED-PHASE-AUTHORIZATION-010 @spec BOUNDED-PHASE-AUTHORIZATION-011
class BoundedDelegatedAction < ApplicationRecord
  ACTIONS = %w[review repair merge].freeze
  RESERVED_ACTIONS = %w[
    product_decision feature_approval release deployment setting_enablement
  ].freeze
  STATUSES = %w[active reassessment_required revoked completed].freeze
  INTENT_DIGEST_FORMAT = /\Asha256:[a-f0-9]{64}\z/
  LINEAGE_KEY = "lineage"

  belongs_to :account
  belongs_to :project
  belongs_to :issue
  belongs_to :created_by, class_name: "User", optional: true, inverse_of: :created_bounded_delegated_actions
  belongs_to :revoked_by, class_name: "User", optional: true, inverse_of: :revoked_bounded_delegated_actions

  validates :action, presence: true, inclusion: { in: ACTIONS, message: "is not a delegable delivery action" }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :expires_at, presence: true
  validate :evidence_is_bounded
  validate :evidence_is_immutable, on: :update
  validate :lineage_is_bounded
  validate :account_matches_scope
  validate :creator_belongs_to_account
  validate :revoker_belongs_to_account

  scope :active, -> { where(status: "active").where("expires_at > ?", Time.current) }

  # Authorizations on the same-work chain of a work item, newest first. The
  # chain is the existing continuation-lookup lineage (the root work item and
  # its linked pull requests); each candidate still has to cover the work
  # item through {#covers_issue_id?}.
  def self.for_lineage_of(work_item)
    issue_ids = Automation::ContinuationGrantLookup.chain_issue_ids(work_item)
    return none if issue_ids.empty?

    where(issue_id: issue_ids).order(id: :desc)
  end

  def allowed?
    active? && ACTIONS.include?(action)
  end

  def admission_snapshot
    evidence.deep_dup
  end

  def active?
    status == "active" && expires_at > Time.current
  end

  def reassessment_required?
    status == "reassessment_required"
  end

  def revoked?
    status == "revoked"
  end

  def completed?
    status == "completed"
  end

  def expired?
    status == "active" && expires_at <= Time.current
  end

  # The pinned same-work lineage: the identified work item plus every chain
  # member recorded at admission. Empty for legacy authorizations admitted
  # before lineage pinning; those govern only their identified work item.
  # @spec BOUNDED-PHASE-AUTHORIZATION-001
  def pinned_lineage
    lineage = evidence.to_h[LINEAGE_KEY]
    lineage.is_a?(Array) ? lineage.map(&:to_i) : []
  end

  # Whether this authorization governs the given work item id: its identified
  # work item or a member of its pinned lineage, nothing wider.
  # @spec BOUNDED-PHASE-AUTHORIZATION-001 @spec BOUNDED-PHASE-AUTHORIZATION-002
  def covers_issue_id?(issue_id)
    issue_id = issue_id.to_i
    self.issue_id == issue_id || pinned_lineage.include?(issue_id)
  end

  # The selected execution phase, an Automation::Phases value.
  def selected_phase
    evidence.to_h["phase"]
  end

  # The selected exclusive stop boundary, an Automation::Phases value.
  def stop_before_phase
    evidence.to_h["stop_before_phase"]
  end

  # True when entering `phase` would cross this authorization's selected
  # stop boundary: the stop phase itself or any later delivery phase. The
  # stop is exclusive and survives terminal lifecycle states.
  # @spec BOUNDED-PHASE-AUTHORIZATION-003
  def stops_phase?(phase)
    stop_index = Automation::Phases::DELIVERY_CHAIN.index(stop_before_phase.to_s)
    phase_index = Automation::Phases::DELIVERY_CHAIN.index(phase.to_s)
    stop_index.present? && phase_index.present? && phase_index >= stop_index
  end

  # True when `phase` is this authorization's selected execution phase.
  def selects_phase?(phase)
    selected_phase.present? && selected_phase.to_s == phase.to_s
  end

  def complete!
    completed = false
    with_lock do
      next false unless status == "active"

      update!(status: "completed", completed_at: Time.current)
      Audit::RecordEvent.call(
        action: "bounded_action.completed",
        actor: nil,
        subject: self,
        metadata: { "action" => action, "stop_before_phase" => evidence.to_h["stop_before_phase"] }
      )
      completed = true
    end
    completed
  end

  # Lifecycle write only: caller surfaces reach this through
  # Automation::RevokeBoundedAction, which enforces the action-specific
  # project policy before revocation. The model still fails closed on
  # cross-account revokers via revoker_belongs_to_account.
  def revoke!(user:)
    with_lock do
      return false unless status.in?(%w[active reassessment_required])

      update!(status: "revoked", revoked_at: Time.current, revoked_by: user)
      Audit::RecordEvent.call(
        action: "bounded_action.revoked",
        actor: user,
        subject: self,
        metadata: { "action" => action }
      )
    end
    true
  end

  # A scope/policy invalidator pauses future admissions. The transition is
  # deliberately idempotent: repeated boundary checks retain the first
  # auditable decision instead of creating an event storm.
  # @spec BOUNDED-PHASE-AUTHORIZATION-005
  def require_reassessment!(reasons:)
    with_lock do
      return false unless status == "active"

      update!(status: "reassessment_required", reassessment_required_at: Time.current,
        reassessment_reasons: Array(reasons).map(&:to_s).uniq.sort)
      Audit::RecordEvent.call(
        action: "bounded_action.reassessment_required",
        subject: self,
        metadata: { "action" => action, "reasons" => reassessment_reasons }
      )
      true
    end
  end

  def resume_reassessment!
    with_lock do
      return false unless reassessment_required?

      update!(status: "active", reassessment_required_at: nil, reassessment_reasons: [])
      true
    end
  end

  private

  def evidence_is_bounded
    errors.add(:evidence, "must be an object") unless evidence.is_a?(Hash)
    return unless evidence.is_a?(Hash)

    validate_intent_digest
    return if evidence["acceptance_refs"].is_a?(Array) && evidence["acceptance_refs"].any?(&:present?)

    errors.add(:evidence, "must include acceptance_refs")
  end

  def evidence_is_immutable
    return unless will_save_change_to_evidence?

    errors.add(:evidence, "cannot be changed after admission")
  end

  # The pinned lineage is optional (legacy admissions predate it) but, when
  # present, it must be a list of work item ids that includes the identified
  # work item, so an authorization can never claim a lineage it is not part
  # of.
  # @spec BOUNDED-PHASE-AUTHORIZATION-001
  def lineage_is_bounded
    lineage = evidence.to_h[LINEAGE_KEY] if evidence.is_a?(Hash)
    return if lineage.nil?

    unless lineage.is_a?(Array) && lineage.all? { |id| id.is_a?(Integer) }
      return errors.add(:evidence, "lineage must be a list of work item ids")
    end

    errors.add(:evidence, "lineage must include the identified work item") unless lineage.include?(issue_id)
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
end
