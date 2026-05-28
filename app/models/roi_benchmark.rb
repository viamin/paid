# frozen_string_literal: true

class RoiBenchmark < ApplicationRecord
  BENCHMARK_TYPES = %w[human_only commercial_agent].freeze

  belongs_to :project

  validates :name, presence: true, length: { maximum: 255 }
  validates :benchmark_type, presence: true, inclusion: { in: BENCHMARK_TYPES }
  validates :tool_name, length: { maximum: 100 }, allow_blank: true
  validates :accepted_pr_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :cost_per_accepted_pr_cents, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :average_cycle_time_hours, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :merge_rate, :rework_rate, :defect_escape_rate,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 },
    allow_nil: true
  validate :commercial_agent_requires_tool_name
  validate :ends_at_not_before_starts_at

  scope :recent, -> { order(ends_at: :desc, created_at: :desc) }

  def benchmark_label
    return "#{name} (#{tool_name})" if commercial_agent? && tool_name.present?

    name
  end

  def commercial_agent?
    benchmark_type == "commercial_agent"
  end

  private

  def commercial_agent_requires_tool_name
    return unless commercial_agent?
    return if tool_name.present?

    errors.add(:tool_name, "is required for commercial agent benchmarks")
  end

  def ends_at_not_before_starts_at
    return if starts_at.blank? || ends_at.blank?
    return if ends_at >= starts_at

    errors.add(:ends_at, "must be on or after the start date")
  end
end
