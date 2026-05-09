# frozen_string_literal: true

require "zlib"

class ScalingExperiment < ApplicationRecord
  STATUSES = %w[draft running completed cancelled].freeze
  DIMENSIONS = %w[agent_count iteration_count max_iterations parallelism].freeze
  OUTCOME_METRIC_KEYS = %w[
    success_rate
    duration_seconds
    total_cost_cents
    agent_launch_success_rate
    blocked_task_rate
    parallelism_observed
  ].freeze

  belongs_to :project

  has_many :scaling_experiment_assignments, dependent: :destroy

  validates :name, presence: true, length: { maximum: 255 }
  validates :hypothesis, presence: true
  validates :dimension, presence: true, inclusion: { in: DIMENSIONS }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :control_value, numericality: { only_integer: true, greater_than: 0 }
  validates :min_samples_per_value, numericality: { only_integer: true, greater_than_or_equal_to: 2 }
  validates :traffic_percentage, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validate :values_tested_are_positive_integers
  validate :control_value_in_values_tested
  validate :context_filter_is_object
  validate :independent_variables_is_array
  validate :outcome_metrics_is_array
  validate :control_definition_is_object
  validate :cohort_settings_is_object
  validate :primary_dimension_variable_matches_plan
  validate :outcome_metrics_are_supported
  validate :primary_outcome_metric_present

  scope :draft, -> { where(status: "draft") }
  scope :running, -> { where(status: "running") }
  scope :completed, -> { where(status: "completed") }
  scope :cancelled, -> { where(status: "cancelled") }

  def self.active_for(project:, dimension:, workflow_id:, task_count:)
    experiment = running.where(project:, dimension:).order(:id).first
    return nil unless experiment
    return nil unless experiment.includes_traffic?(workflow_id:)
    return nil unless experiment.matches_context?(task_count:)

    experiment
  end

  def running?
    status == "running"
  end

  def draft?
    status == "draft"
  end

  def start!
    with_lock do
      reload
      raise_invalid_status!("start") unless draft?

      update!(status: "running", started_at: Time.current)
    end
  rescue ActiveRecord::RecordNotUnique
    errors.add(:base, "another scaling experiment is already running for this dimension")
    raise ActiveRecord::RecordInvalid, self
  end

  def complete!
    with_lock do
      reload
      raise_invalid_status!("complete") unless running?

      update!(status: "completed", completed_at: Time.current)
    end
  end

  def cancel!
    with_lock do
      reload
      raise_invalid_status!("cancel") unless %w[draft running].include?(status)

      update!(status: "cancelled", completed_at: Time.current)
    end
  end

  def includes_traffic?(workflow_id:)
    return false if traffic_percentage.zero?
    return true if traffic_percentage == 100

    Zlib.crc32("#{id}:#{workflow_id}") % 100 < traffic_percentage
  end

  def matches_context?(task_count:)
    return false if task_count.to_i < min_task_count
    return false if max_task_count && task_count.to_i > max_task_count

    true
  end

  def eligible_values(task_count:)
    case dimension
    when "agent_count", "parallelism"
      normalized_values_tested.select { |value| value <= task_count.to_i }
    else
      normalized_values_tested
    end
  end

  def cohort_label(task_count:, assigned_value:)
    format(
      cohort_label_template,
      dimension: dimension,
      value: assigned_value,
      task_bucket: cohort_task_bucket(task_count:)
    )
  end

  def sufficient_samples?
    sample_counts = recorded_sample_counts
    normalized_values_tested.all? { |value| sample_counts.fetch(value, 0) >= min_samples_per_value }
  end

  def samples_key
    recorded_counts = recorded_sample_counts

    normalized_values_tested
      .map { |value| "#{value}:#{recorded_counts.fetch(value, 0)}" }
      .join(",")
  end

  def cached_or_compute_summary(persist: true)
    current_key = samples_key
    if cached_summary.present?
      return cached_summary if summary_samples_key == current_key
      return cached_summary unless persist
    end

    summary = ScalingExperiments::SummarizeResults.call(scaling_experiment: self)
    return summary unless persist

    update_columns(cached_summary: summary, summary_samples_key: current_key)
    summary
  end

  private

  def normalized_values_tested
    Array(values_tested).map { |value| Integer(value) }.uniq.sort
  rescue ArgumentError, TypeError
    []
  end

  def recorded_sample_counts
    scaling_experiment_assignments
      .recorded
      .group(:assigned_value)
      .count
      .transform_keys(&:to_i)
  end

  def min_task_count
    context_filter.fetch("min_task_count", 2).to_i
  end

  def max_task_count
    raw = context_filter["max_task_count"]
    return nil if raw.blank?

    raw.to_i
  end

  def cohort_label_template
    cohort_settings.fetch("label_template", "%<dimension>s-%<value>s__%<task_bucket>s")
  end

  def cohort_task_bucket(task_count:)
    bucket = Array(cohort_settings["task_count_buckets"]).find do |candidate|
      minimum = candidate["min"].to_i
      maximum = candidate["max"]

      task_count.to_i >= minimum && (maximum.blank? || task_count.to_i <= maximum.to_i)
    end

    bucket&.fetch("label", nil) || "tasks-unspecified"
  end

  def raise_invalid_status!(action)
    errors.add(:base, "cannot #{action} an experiment that is #{status}")
    raise ActiveRecord::RecordInvalid, self
  end

  def values_tested_are_positive_integers
    values = Array(values_tested)
    if values.blank?
      errors.add(:values_tested, "must include at least one value")
      return
    end

    normalized = values.filter_map do |value|
      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end

    if normalized.size != values.size || normalized.any?(&:zero?) || normalized.any?(&:negative?)
      errors.add(:values_tested, "must contain unique positive integers")
      return
    end

    return if normalized.uniq.size == normalized.size

    errors.add(:values_tested, "must contain unique positive integers")
  end

  def control_value_in_values_tested
    return if values_tested.blank?
    return if normalized_values_tested.include?(control_value.to_i)

    errors.add(:control_value, "must be included in values_tested")
  end

  def context_filter_is_object
    return if context_filter.is_a?(Hash)

    errors.add(:context_filter, "must be an object")
  end

  def independent_variables_is_array
    return if independent_variables.is_a?(Array)

    errors.add(:independent_variables, "must be an array")
  end

  def outcome_metrics_is_array
    return if outcome_metrics.is_a?(Array)

    errors.add(:outcome_metrics, "must be an array")
  end

  def control_definition_is_object
    return if control_definition.is_a?(Hash)

    errors.add(:control_definition, "must be an object")
  end

  def cohort_settings_is_object
    return if cohort_settings.is_a?(Hash)

    errors.add(:cohort_settings, "must be an object")
  end

  def primary_dimension_variable_matches_plan
    return unless independent_variables.is_a?(Array)

    primary_variable = independent_variables.find { |variable| variable.is_a?(Hash) && variable["key"] == dimension }
    if primary_variable.blank?
      errors.add(:independent_variables, "must include the tested dimension")
      return
    end

    variable_values = Array(primary_variable["values"]).map(&:to_i).uniq.sort
    return if variable_values == normalized_values_tested && primary_variable["control_value"].to_i == control_value

    errors.add(:independent_variables, "must match values_tested and control_value for the tested dimension")
  end

  def outcome_metrics_are_supported
    return unless outcome_metrics.is_a?(Array)

    invalid_keys = outcome_metrics.filter_map do |metric|
      next unless metric.is_a?(Hash)

      key = metric["key"].to_s
      key unless OUTCOME_METRIC_KEYS.include?(key)
    end
    return if invalid_keys.empty?

    errors.add(:outcome_metrics, "contains unsupported keys: #{invalid_keys.sort.join(', ')}")
  end

  def primary_outcome_metric_present
    return unless outcome_metrics.is_a?(Array)
    return if outcome_metrics.any? { |metric| metric.is_a?(Hash) && metric["primary"] == true }

    errors.add(:outcome_metrics, "must include one primary metric")
  end
end
