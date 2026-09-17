# frozen_string_literal: true

# An open product decision blocking a feature intent's approval: a clarifying
# question Paid could not answer from the repository, or an AI-inferred
# decision awaiting human confirmation. Each one names the design claim it
# affects so the Inbox can explain what it holds (RDR-066 "Discovery and
# approval readiness").
# @spec FEATURE-APPROVAL-006 @spec FEATURE-APPROVAL-007
class FeatureIntentDecision < ApplicationRecord
  KINDS = %w[question inferred_decision].freeze
  STATUSES = %w[open resolved].freeze

  belongs_to :feature_intent
  belongs_to :resolved_by, class_name: "User", optional: true

  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :design_claim, presence: true
  validates :prompt, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :open_decisions, -> { where(status: "open") }
  scope :questions, -> { where(kind: "question") }
  scope :inferred_decisions, -> { where(kind: "inferred_decision") }

  def question? = kind == "question"
  def inferred_decision? = kind == "inferred_decision"
  def open? = status == "open"

  def resolve!(by:, answer:)
    update!(status: "resolved", answer: answer, resolved_by: by, resolved_at: Time.current)
    FeatureIntents::EvaluateCriteriaClarityJob.perform_later(feature_intent_id: feature_intent_id)
    Dashboard::CacheVersion.bump(feature_intent.project.account, scope: Dashboard::CacheVersion::INBOX_SCOPE)
  end
end
