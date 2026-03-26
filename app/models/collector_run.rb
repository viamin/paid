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

  def complete!(artifacts_count: 0)
    update!(
      status: "completed",
      completed_at: Time.current,
      duration_ms: started_at ? ((Time.current - started_at) * 1000).to_i : nil,
      artifacts_count: artifacts_count
    )
  end

  def fail!(error_message:)
    update!(
      status: "failed",
      completed_at: Time.current,
      duration_ms: started_at ? ((Time.current - started_at) * 1000).to_i : nil,
      error_message: error_message
    )
  end

  def start!
    update!(status: "running", started_at: Time.current)
  end
end
