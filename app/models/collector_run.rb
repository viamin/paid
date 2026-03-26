# frozen_string_literal: true

class CollectorRun < ApplicationRecord
  STATUSES = %w[pending running completed failed stale].freeze

  belongs_to :project_version

  has_many :knowledge_artifacts, dependent: :destroy

  validates :collector_type, presence: true, length: { maximum: 100 }
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :by_status, ->(status) { where(status: status) }
  scope :completed, -> { where(status: "completed") }
  scope :failed, -> { where(status: "failed") }
  scope :running, -> { where(status: "running") }

  def mark_running!
    update!(status: "running", started_at: Time.current)
  end

  def mark_completed!(count:)
    now = Time.current
    update!(
      status: "completed",
      completed_at: now,
      duration_ms: started_at ? ((now - started_at) * 1000).to_i : nil,
      artifacts_count: count
    )
  end

  def mark_failed!(error:)
    now = Time.current
    update!(
      status: "failed",
      completed_at: now,
      duration_ms: started_at ? ((now - started_at) * 1000).to_i : nil,
      error_message: error
    )
  end
end
