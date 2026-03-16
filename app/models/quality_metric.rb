# frozen_string_literal: true

class QualityMetric < ApplicationRecord
  METRIC_TYPES = %w[automated human].freeze
  FEEDBACK_SOURCES = %w[system pr_merge pr_reaction pr_review webhook].freeze

  # Weights from RDR-009 for composite quality score
  SCORE_WEIGHTS = {
    "pr_created" => 0.30,
    "ci_passed" => 0.20,
    "pr_merged" => 0.30,
    "iterations" => 0.15,
    "lint_clean" => 0.10,
    "tests_pass" => 0.05
  }.freeze

  belongs_to :agent_run
  belongs_to :prompt_version, optional: true

  validates :metric_type, presence: true, inclusion: { in: METRIC_TYPES }
  validates :feedback_source, inclusion: { in: FEEDBACK_SOURCES }, allow_nil: true
  validates :composite_score,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },
    allow_nil: true
  validates :metric_type, uniqueness: { scope: :agent_run_id }

  scope :automated, -> { where(metric_type: "automated") }
  scope :human, -> { where(metric_type: "human") }
  scope :by_prompt_version, ->(prompt_version_id) { where(prompt_version_id: prompt_version_id) }
  scope :by_project, ->(project_id) { joins(:agent_run).where(agent_runs: { project_id: project_id }) }
  scope :by_time_period, ->(start_date, end_date) { where(created_at: start_date..end_date) }
  scope :with_composite_score, -> { where.not(composite_score: nil) }
  scope :recent, -> { order(created_at: :desc) }

  # Computes a weighted average from a hash of scores using RDR-009 weights.
  # Scores without a defined weight in SCORE_WEIGHTS are ignored.
  #
  # @param scores_hash [Hash{String => Numeric}] Score name to value mapping
  # @return [Float, nil] Weighted average (0.0..1.0), or nil if no weighted scores
  def self.weighted_average(scores_hash)
    return nil if scores_hash.blank?

    total_weight = 0.0
    weighted_sum = 0.0

    scores_hash.each do |key, value|
      weight = SCORE_WEIGHTS[key]
      next unless weight

      total_weight += weight
      weighted_sum += weight * value.to_f
    end

    return nil if total_weight.zero?

    (weighted_sum / total_weight).round(4)
  end

  # Calculates composite score from individual scores using RDR-009 weights.
  #
  # @return [Float, nil] Score between 0.0 and 1.0, or nil if no scores
  def calculate_composite_score
    self.class.weighted_average(scores)
  end

  # Calculates and persists the composite score.
  #
  # @return [Float, nil] The calculated composite score
  def calculate_composite_score!
    self.composite_score = calculate_composite_score
    save! if composite_score_changed?
    composite_score
  end
end
