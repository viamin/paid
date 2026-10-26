# frozen_string_literal: true

# A durable, attributable submission for one exact human/external closeout
# prerequisite. Notification state is deliberately not evidence state.
# @spec PARTIAL-CLOSEOUT-030
class PartialCloseoutPrerequisiteEvidence < ApplicationRecord
  OUTCOMES = %w[submitted sufficient insufficient stale unavailable].freeze
  EVIDENCE_TYPES = %w[shadow_evaluation report run artifact link].freeze

  belongs_to :account
  belongs_to :issue
  belongs_to :actor, class_name: "User"
  belongs_to :shadow_evaluation, class_name: "IntentConformanceShadowEvaluation", optional: true

  validates :criterion, :source_revision, :intent_revision, :evidence_type, :evidence_reference, :explanation, :idempotency_key, presence: true
  validates :outcome, inclusion: { in: OUTCOMES }
  validates :evidence_type, inclusion: { in: EVIDENCE_TYPES }
  validates :idempotency_key, uniqueness: { scope: :account_id }
  validate :tenant_owns_issue_and_actor

  def current_for?(issue)
    source_revision == Issues::CloseoutEvidence.call(issue).digest &&
      intent_revision == PartialCloseouts::Assessment.intent_revision_for(issue)
  end

  private

  def tenant_owns_issue_and_actor
    errors.add(:issue, "must belong to the evidence account") if issue && issue.project.account_id != account_id
    errors.add(:actor, "must belong to the evidence account") if actor && actor.account_id != account_id
  end
end
