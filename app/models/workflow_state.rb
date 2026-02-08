# frozen_string_literal: true

class WorkflowState < ApplicationRecord
  FINISHED_STATUSES = %w[completed failed cancelled timed_out].freeze
  STATUSES = (%w[running] + FINISHED_STATUSES).freeze

  belongs_to :project, optional: true

  validates :temporal_workflow_id, presence: true, uniqueness: true
  validates :workflow_type, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :active, -> { where(status: "running") }
  scope :finished, -> { where(status: FINISHED_STATUSES) }

  def running?
    status == "running"
  end

  def finished?
    FINISHED_STATUSES.include?(status)
  end
end
