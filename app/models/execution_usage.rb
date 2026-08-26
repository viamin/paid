# frozen_string_literal: true

# Per-run infrastructure usage and cost summary, distinct from
# ContainerMetric's high-frequency samples. One row per AgentRun,
# captured at termination, so cloud-provider spend can be measured
# separately from LLM token cost. See
# docs/intent/execution-usage-and-cost-accounting/ for the spec.
class ExecutionUsage < ApplicationRecord
  TERMINATION_REASONS = %w[completed cancelled timed_out failed evicted].freeze

  belongs_to :agent_run

  validates :runner_backend, presence: true, length: { maximum: 64 }
  validates :provider_resource_id, length: { maximum: 255 }, allow_nil: true
  validates :provisioned_at, :terminated_at, presence: true
  validates :billed_duration_seconds, numericality: { greater_than_or_equal_to: 0 }
  validates :infra_cost_cents, numericality: { greater_than_or_equal_to: 0 }
  validates :rate_cents_per_hour, numericality: { greater_than_or_equal_to: 0 }
  validates :requested_cpu_cores, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :requested_memory_mib, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :requested_disk_gb, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :termination_reason, presence: true, inclusion: { in: TERMINATION_REASONS }
  validate :timestamps_are_ordered

  scope :by_runner_backend, ->(backend) { where(runner_backend: backend.to_s) }
  scope :terminated_in, ->(start_time, end_time) { where(terminated_at: start_time..end_time) }
  scope :with_cost, -> { where("infra_cost_cents > 0") }

  def completed_termination?
    termination_reason == "completed"
  end

  private

  def timestamps_are_ordered
    return if provisioned_at.blank? || terminated_at.blank?
    return if terminated_at >= provisioned_at

    errors.add(:terminated_at, "must be on or after provisioned_at")
  end
end
