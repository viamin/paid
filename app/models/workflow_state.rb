# frozen_string_literal: true

class WorkflowState < ApplicationRecord
  belongs_to :project, optional: true

  validates :temporal_workflow_id, presence: true, uniqueness: true
  validates :workflow_type, presence: true
  validates :status, presence: true

  enum :status, {
    running: "running",
    completed: "completed",
    failed: "failed",
    cancelled: "cancelled",
    timed_out: "timed_out"
  }, default: :running

  scope :active, -> { where(status: :running) }
  scope :finished, -> { where(status: %i[completed failed cancelled timed_out]) }
end
