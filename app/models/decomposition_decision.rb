# frozen_string_literal: true

class DecompositionDecision < ApplicationRecord
  DECISION_TYPES = %w[decomposition_strategy planning_outcome parallelization_outcome].freeze
  POLICY_OUTCOME_DECISION_TYPES = %w[planning_outcome parallelization_outcome].freeze
  PLAN_PENDING_REVIEW_OUTCOME = "plan_pending_review"

  belongs_to :project
  belongs_to :issue

  validates :decision_key, presence: true, uniqueness: true
  validates :workflow_name, :workflow_id, :decision_type, :outcome, presence: true
  validates :decision_type, inclusion: { in: DECISION_TYPES }

  scope :for_workflow, ->(workflow_id) { where(workflow_id: workflow_id) }
  scope :for_issue, ->(issue) { where(issue: issue) }
  scope :latest_for_workflow, lambda {
    where(<<~SQL.squish)
      NOT EXISTS (
        SELECT 1
        FROM decomposition_decisions newer
        WHERE newer.workflow_id = decomposition_decisions.workflow_id
          AND (
            newer.created_at > decomposition_decisions.created_at
            OR (newer.created_at = decomposition_decisions.created_at AND newer.id > decomposition_decisions.id)
          )
      )
    SQL
  }
  scope :open_plan_reviews, lambda {
    latest_for_workflow.where(
      decision_type: "planning_outcome",
      outcome: PLAN_PENDING_REVIEW_OUTCOME
    )
  }
end
