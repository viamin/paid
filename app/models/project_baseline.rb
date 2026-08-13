# frozen_string_literal: true

class ProjectBaseline < ApplicationRecord
  METRIC_NAMES = %w[
    tokens_total
    duration_seconds
    iterations
    cost_cents
  ].freeze

  belongs_to :project

  validates :metric_name, presence: true, inclusion: { in: METRIC_NAMES },
    uniqueness: { scope: :project_id }
  validates :mean, :standard_deviation, :p95, :sample_count, presence: true
  validates :sample_count, numericality: { greater_than_or_equal_to: 0 }
end
