# frozen_string_literal: true

class AgentRunLog < ApplicationRecord
  LOG_TYPES = %w[stdout stderr system metric].freeze

  # Discriminator stored in metadata["type"] for per-provider issue-analysis
  # failure entries (log_type "system"). Keeps these entries queryable/groupable
  # without adding a new log_type value.
  # @spec ISSUE-ANALYSIS-013
  PROVIDER_FAILURE_TYPE = "issue_analysis_provider_failure"

  belongs_to :agent_run

  validates :log_type, presence: true, inclusion: { in: LOG_TYPES }
  validates :content, presence: true

  scope :by_type, ->(type) { where(log_type: type) }
  scope :stdout, -> { where(log_type: "stdout") }
  scope :stderr, -> { where(log_type: "stderr") }
  scope :system, -> { where(log_type: "system") }
  scope :metric, -> { where(log_type: "metric") }
  scope :recent, -> { order(created_at: :desc) }
  scope :chronological, -> { order(created_at: :asc) }
  scope :provider_failures, -> { system.where("metadata ->> 'type' = ?", PROVIDER_FAILURE_TYPE) }

  # @spec ISSUE-ANALYSIS-013
  # Lets failure-pattern detection group provider-attempt failures on the
  # normalized category instead of free-text error messages.
  def self.provider_failure_categories(agent_run_ids)
    provider_failures.where(agent_run_id: agent_run_ids).group("metadata ->> 'failure_category'").count
  end
end
