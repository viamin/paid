# frozen_string_literal: true

class TokenUsage < ApplicationRecord
  REQUEST_TYPES = %w[agent planning evaluation run_summary].freeze

  belongs_to :agent_run

  validates :request_type, presence: true, inclusion: { in: REQUEST_TYPES }
  validates :input_tokens, numericality: { greater_than_or_equal_to: 0 }
  validates :output_tokens, numericality: { greater_than_or_equal_to: 0 }
  validates :cost_cents, numericality: { greater_than_or_equal_to: 0 }
  validates :llm_model, length: { maximum: 100 }

  scope :by_project, ->(project_id) { joins(:agent_run).where(agent_runs: { project_id: project_id }) }
  scope :by_model, ->(llm_model) { where(llm_model: llm_model) }
  scope :by_request_type, ->(type) { where(request_type: type) }
  scope :by_time_period, ->(start_time, end_time) { where(created_at: start_time..end_time) }
  # Billable scope avoids double-counting by excluding run_summary records
  # for agent runs that also have per-request proxy records. When the secrets
  # proxy is NOT used (non-proxy mode), run_summary is the only usage source
  # and must be included.
  scope :billable, -> {
    runs_with_proxy = where.not(request_type: "run_summary").select(:agent_run_id).distinct
    where.not(request_type: "run_summary")
      .or(where(request_type: "run_summary").where.not(agent_run_id: runs_with_proxy))
  }

  def total_tokens
    input_tokens + output_tokens
  end

  def self.total_cost_cents
    sum(:cost_cents)
  end

  def self.total_input_tokens
    sum(:input_tokens)
  end

  def self.total_output_tokens
    sum(:output_tokens)
  end

  def self.cost_by_model
    group(:llm_model).sum(:cost_cents)
  end

  def self.cost_by_request_type
    group(:request_type).sum(:cost_cents)
  end

  def self.daily_costs(days: 30)
    where(created_at: days.days.ago..)
      .group("DATE(created_at)")
      .sum(:cost_cents)
  end
end
