# frozen_string_literal: true

class WorkflowState < ApplicationRecord
  STATUSES = %w[running completed failed cancelled timed_out].freeze

  belongs_to :project, optional: true

  validates :temporal_workflow_id, presence: true, uniqueness: true
  validates :workflow_type, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :active, -> { where(status: "running") }
  scope :finished, -> { where(status: %w[completed failed cancelled timed_out]) }

  def running?
    status == "running"
  end

  def finished?
    %w[completed failed cancelled timed_out].include?(status)
  end
end
