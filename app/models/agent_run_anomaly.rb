# frozen_string_literal: true

class AgentRunAnomaly < ApplicationRecord
  ANOMALY_TYPES = %w[high_value low_value].freeze
  SEVERITIES = %w[warning critical].freeze

  belongs_to :agent_run
  belongs_to :project

  validates :anomaly_type, presence: true, inclusion: { in: ANOMALY_TYPES }
  validates :severity, presence: true, inclusion: { in: SEVERITIES }
  validates :metric_name, presence: true, inclusion: { in: ProjectBaseline::METRIC_NAMES },
    uniqueness: { scope: :agent_run_id }
  validates :metric_value, :baseline_mean, :baseline_standard_deviation, :deviation_factor, presence: true
  validate :project_matches_agent_run

  scope :warnings, -> { where(severity: "warning") }
  scope :critical, -> { where(severity: "critical") }
  scope :recent, -> { where(created_at: 24.hours.ago..) }

  private

  def project_matches_agent_run
    return unless project && agent_run
    return if project_id == agent_run.project_id

    errors.add(:project, "must match the agent run project")
  end
end
