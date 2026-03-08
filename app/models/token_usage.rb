# frozen_string_literal: true

class TokenUsage < ApplicationRecord
  REQUEST_TYPES = %w[agent planning evaluation].freeze

  belongs_to :agent_run

  validates :request_type, presence: true, inclusion: { in: REQUEST_TYPES }
  validates :input_tokens, numericality: { greater_than_or_equal_to: 0 }
  validates :output_tokens, numericality: { greater_than_or_equal_to: 0 }
  validates :cost_cents, numericality: { greater_than_or_equal_to: 0 }
  validates :model_name, length: { maximum: 100 }

  scope :by_project, ->(project_id) { joins(:agent_run).where(agent_runs: { project_id: project_id }) }
  scope :by_model, ->(model_name) { where(model_name: model_name) }
  scope :by_request_type, ->(type) { where(request_type: type) }
  scope :by_time_period, ->(start_time, end_time) { where(created_at: start_time..end_time) }

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
    group(:model_name).sum(:cost_cents)
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
