# frozen_string_literal: true

# @spec INTENT-AMENDMENT-003 @spec INTENT-CONFORMANCE-REVIEW-001 @spec FEATURE-APPROVAL-009 @spec FEATURE-APPROVAL-010
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

  # Statuses a Mark approved action may originate from: the design is still
  # open, a decision resolved it back into review, it was explicitly marked
  # ready, or a prior approval is being refreshed against a new PR head.
  APPROVABLE_STATUSES = %w[design_open needs_decision ready_for_approval approved_waiting_for_merge].freeze

  CRITERIA_CLARITY_STATES = %w[pending clear vague].freeze

  belongs_to :project
  belongs_to :approved_by, class_name: "User", optional: true

  has_many :feature_intent_issues, dependent: :destroy
  has_many :issues, through: :feature_intent_issues
  has_many :feature_intent_decisions, dependent: :destroy
  has_many :feature_intent_design_prs, dependent: :destroy
  has_many :design_amendments, dependent: :restrict_with_error

  validates :title, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :criteria_clarity_state, presence: true, inclusion: { in: CRITERIA_CLARITY_STATES }

  scope :released, -> { where(status: "released") }
  scope :awaiting_approval, -> { where(status: APPROVABLE_STATUSES) }

  def released? = status == "released"
  def revising? = status == "revising"
  def approved_waiting_for_merge? = status == "approved_waiting_for_merge"
  def criteria_clarity_clear? = criteria_clarity_state == "clear"

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
  def record_approval!(by:, pr_heads:)
    raise InvalidTransitionError, "cannot approve a #{status} feature intent" unless status.in?(APPROVABLE_STATUSES)

    update!(
      status: "approved_waiting_for_merge",
      approved_by: by,
      approved_at: Time.current,
      approved_pr_heads: pr_heads
    )
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
    transition_to!("released", from: %w[revising released])
  end

  private

  def transition_to!(next_status, from:)
    raise InvalidTransitionError, "cannot move feature intent from #{status} to #{next_status}" unless status.in?(from)

    update!(status: next_status)
  end

  # Raised when an amendment flow requests a lifecycle move the feature's
  # current state does not allow (e.g. amending a feature that was never
  # released).
  class InvalidTransitionError < StandardError; end
end
