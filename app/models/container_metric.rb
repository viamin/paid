# frozen_string_literal: true

class ContainerMetric < ApplicationRecord
  belongs_to :agent_run

  validates :container_id, presence: true, length: { maximum: 128 }
  validates :cpu_percent, numericality: { greater_than_or_equal_to: 0.0 }
  validates :memory_bytes, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :memory_limit_bytes, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :memory_percent, numericality: { greater_than_or_equal_to: 0.0 }
  validates :pids_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :recorded_at, presence: true

  scope :for_run, ->(agent_run_id) { where(agent_run_id: agent_run_id).order(:recorded_at) }
  scope :recent, -> { order(recorded_at: :desc) }

  def memory_mb
    memory_bytes / (1024.0 * 1024)
  end

  def memory_limit_mb
    memory_limit_bytes / (1024.0 * 1024)
  end
end
