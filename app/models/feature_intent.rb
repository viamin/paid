# frozen_string_literal: true

# @spec INTENT-AMENDMENT-003 @spec INTENT-CONFORMANCE-REVIEW-001 @spec FEATURE-APPROVAL-009 @spec FEATURE-APPROVAL-010 @spec FEATURE-APPROVAL-020 @spec CONFIDENCE-DELIVERY-001
# RDR-066 feature intent: links a feature's brief, discovery decisions,
# design PRs, issue tree, and approval record. The RDR-067 amendment flow
# (`released`/`revising` transitions) and the intent-conformance reviewer
# (#3866, reading +design_document_paths+ at +approved_design_revision+)
# are wired here. The RDR-066 Inbox approval lifecycle (#3864) extends this
# record with open decisions, linked design PRs, and the Mark approved
# transition.
class FeatureIntent < ApplicationRecord
  STATUSES = %w[
    discovering
    design_open
    needs_decision
    ready_for_approval
    approved_waiting_for_merge
    released
    revising
    cancelled
  ].freeze

  TERMINAL_STATUSES = %w[released revising cancelled].freeze

  # Statuses a Mark approved action may originate from: the design is still
  # open, a decision resolved it back into review, it was explicitly marked
  # ready, or a prior approval is being refreshed against a new PR head.
  APPROVABLE_STATUSES = %w[design_open needs_decision ready_for_approval approved_waiting_for_merge].freeze

  CRITERIA_CLARITY_STATES = %w[pending clear vague].freeze
  CANCELLATION_REASONS = %w[already_handled no_longer_wanted superseded].freeze
  DELIVERY_POLICIES = Project::FEATURE_DELIVERY_POLICIES

  belongs_to :project
  belongs_to :approved_by, class_name: "User", optional: true
  belongs_to :cancelled_by, class_name: "User", optional: true

  has_many :feature_intent_issues, dependent: :destroy
  has_many :issues, through: :feature_intent_issues
  has_many :feature_intent_decisions, dependent: :destroy
  has_many :feature_intent_design_prs, dependent: :destroy
  has_many :feature_intent_approval_revisions, dependent: :restrict_with_error
  has_many :design_amendments, dependent: :restrict_with_error
  has_one :feature_intent_completion, dependent: :destroy

  validates :title, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :criteria_clarity_state, presence: true, inclusion: { in: CRITERIA_CLARITY_STATES }
  validates :delivery_policy, presence: true, inclusion: { in: DELIVERY_POLICIES }
  validates :cancellation_reason, inclusion: { in: CANCELLATION_REASONS }, allow_nil: true
  validates :replacement_reference, format: { with: %r{\Ahttps?://\S+\z}i, message: "must be an http(s) URL" }, allow_blank: true

  attr_readonly :delivery_policy

  scope :released, -> { where(status: "released") }
  scope :awaiting_approval, -> { where(status: APPROVABLE_STATUSES) }

  # Single choke point for matching a FeatureIntent to the issue that
  # introduced it. Both the `create_feature`/`lid_planning` run paths
  # (attach and reconcile) and the closed-unmerged webhook reconciliation
  # must agree on this predicate — silently diverging matching logic
  # between the create path and the reconcile path is the exact failure
  # mode the choke-point design in the service docs is meant to prevent.
  scope :linked_to_issue, ->(issue) {
    where(project_id: issue.project_id)
      .joins(:feature_intent_issues)
      .where(feature_intent_issues: { issue_id: issue.id })
  }

  def released? = status == "released"
  def revising? = status == "revising"
  def approved_waiting_for_merge? = status == "approved_waiting_for_merge"
  def criteria_clarity_clear? = criteria_clarity_state == "clear"
  def approval_gated? = delivery_policy == "approval_gated"
  def confidence_driven? = delivery_policy == "confidence_driven"

  def cancelled? = status == "cancelled"

  # Persists the CriteriaClarityReview verdict (or the fail-closed "pending"
  # default) so Inbox rendering never makes a live LLM call per entry
  # (RDR-066 readiness is AI-assisted but AGD-cached, not ZFC-per-render).
  def record_criteria_clarity!(state:, explanation:)
    update!(
      criteria_clarity_state: state,
      criteria_clarity_explanation: explanation,
      criteria_clarity_evaluated_at: Time.current
    )
  end

  # Records a human's Mark approved decision: the actor, time, and the exact
  # design PR heads they reviewed. Callers (Inbox action, direct-merge
  # reconciliation) must gate this on FeatureIntents::ApprovalReadiness and
  # authorization themselves — this method only enforces the lifecycle
  # transition (RDR-066 "Approval sources and revision binding").
  def record_approval!(by:, pr_heads:, source: "inbox")
    with_lock do
      raise InvalidTransitionError, "cannot approve a #{status} feature intent" unless status.in?(APPROVABLE_STATUSES)

      approved_at = Time.current
      revision = feature_intent_approval_revisions.create!(
        approved_by: by,
        approved_at: approved_at,
        source: source,
        pr_heads: pr_heads,
        revision_number: next_approval_revision_number
      )
      update!(status: "approved_waiting_for_merge", approved_by: by, approved_at: approved_at, approved_pr_heads: pr_heads)
      record_approval_audit_event(revision)
    end
    Dashboard::CacheVersion.bump(project.account, scope: Dashboard::CacheVersion::INBOX_SCOPE)
    self
  end

  # Enters `revising` when a design amendment opens. Guarded so only a
  # released feature (an approved baseline exists to amend) can start one.
  def revise!
    transition_to!("revising", from: %w[released])
  end

  # Returns to `released` when the amendment merges (new revision recorded)
  # or is abandoned (prior revision stands).
  def release!
    transition_to!("released", from: %w[approved_waiting_for_merge revising released])
  end

  # Declining retains the design, issue links, evidence, and approval history.
  # It deliberately does not mutate linked issues or runs: their own admission
  # and hold rules remain authoritative until an operator changes them.
  # @spec FEATURE-APPROVAL-020
  def cancel!(by:, reason:, replacement_reference: nil)
    with_lock do
      return self if cancelled?

      raise InvalidTransitionError, "cannot cancel a #{status} feature intent" if status.in?(%w[released revising])

      cancelled_at = Time.current
      update!(
        status: "cancelled",
        cancelled_by: by,
        cancelled_at: cancelled_at,
        cancellation_reason: reason,
        replacement_reference: replacement_reference.presence
      )
      record_cancellation_audit_event
    end
    Dashboard::CacheVersion.bump(project.account, scope: Dashboard::CacheVersion::INBOX_SCOPE)
    self
  end

  # A reopened proposal always returns to discovery. It remains held; reopening
  # never reuses a former approval or releases any linked implementation work.
  # @spec FEATURE-APPROVAL-020
  def reopen!(by:)
    with_lock do
      raise InvalidTransitionError, "cannot reopen a #{status} feature intent" unless cancelled?

      update!(
        status: "discovering",
        cancelled_by: nil,
        cancelled_at: nil,
        cancellation_reason: nil,
        replacement_reference: nil
      )
      record_reopen_audit_event(by)
    end
    Dashboard::CacheVersion.bump(project.account, scope: Dashboard::CacheVersion::INBOX_SCOPE)
    self
  end

  private

  def transition_to!(next_status, from:)
    raise InvalidTransitionError, "cannot move feature intent from #{status} to #{next_status}" unless status.in?(from)

    update!(status: next_status)
  end

  def next_approval_revision_number
    feature_intent_approval_revisions.maximum(:revision_number).to_i + 1
  end

  def record_approval_audit_event(revision)
    Audit::RecordEvent.call(
      action: "feature_intent.approved",
      actor: revision.approved_by,
      subject: self,
      metadata: {
        from_status: status_before_last_save,
        to_status: "approved_waiting_for_merge",
        approval_revision: revision.revision_number,
        source: revision.source,
        pr_heads: revision.pr_heads
      }
    )
  end

  def record_cancellation_audit_event
    Audit::RecordEvent.call(
      action: "feature_intent.cancelled",
      actor: cancelled_by,
      subject: self,
      metadata: {
        reason: cancellation_reason,
        replacement_reference: replacement_reference
      }
    )
  end

  def record_reopen_audit_event(actor)
    Audit::RecordEvent.call(
      action: "feature_intent.reopened",
      actor: actor,
      subject: self,
      metadata: { from_status: "cancelled", to_status: "discovering" }
    )
  end

  # Raised when an amendment flow requests a lifecycle move the feature's
  # current state does not allow (e.g. amending a feature that was never
  # released).
  class InvalidTransitionError < StandardError; end
end
