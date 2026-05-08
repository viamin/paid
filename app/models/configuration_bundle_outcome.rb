# frozen_string_literal: true

class ConfigurationBundleOutcome < ApplicationRecord
  belongs_to :configuration_bundle
  belongs_to :agent_run

  validates :status, presence: true, inclusion: { in: AgentRun::FINISHED_STATUSES }
  validates :quality_score, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
  validates :cost_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :duration_seconds, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :agent_run_id, uniqueness: true
end
