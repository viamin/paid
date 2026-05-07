# frozen_string_literal: true

class DecompositionDecision < ApplicationRecord
  DECISION_TYPES = %w[planning_outcome parallelization_outcome].freeze

  belongs_to :project
  belongs_to :issue

  validates :decision_key, presence: true, uniqueness: true
  validates :workflow_name, :workflow_id, :decision_type, :outcome, presence: true
  validates :decision_type, inclusion: { in: DECISION_TYPES }

  scope :for_workflow, ->(workflow_id) { where(workflow_id: workflow_id) }
  scope :for_issue, ->(issue) { where(issue: issue) }
end
