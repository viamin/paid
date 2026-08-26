# frozen_string_literal: true

class QualityMetric < ApplicationRecord
  METRIC_TYPES = %w[automated human].freeze
  FEEDBACK_SOURCES = %w[system pr_merge pr_reaction pr_review issue_reaction review_reaction enhance_issue_feedback webhook comment].freeze
  SOURCES = %w[agent_run scheduled_mutation_sweep].freeze
  AGENT_RUN_SOURCE = "agent_run"
  SCHEDULED_MUTATION_SWEEP_SOURCE = "scheduled_mutation_sweep"
  MUTATION_KILL_RATE_WEIGHT = 0.10

  # Weights for composite quality score (PR creation goal).
  # Based on RDR-009 with adjustments: added pr_created, review_comment_count,
  # and agent_rerun_count signals; rebalanced weights accordingly.
  #
  # mutation_kill_rate contributes 10% when present. Existing dimensions are
  # scaled to 90% total so runs without mutant data keep prior behavior.
  SCORE_WEIGHTS = {
    "pr_created" => 0.225,
    "ci_passed" => 0.135,
    "pr_merged" => 0.225,
    "iterations" => 0.09,
    "lint_clean" => 0.045,
    "tests_pass" => 0.045,
    "review_comment_count" => 0.045,
    "agent_rerun_count" => 0.09,
    "mutation_kill_rate" => MUTATION_KILL_RATE_WEIGHT
  }.freeze

  FOCUS_WEIGHTS = { # @spec FOCUSED-RUN-004
    "ci_fix" => {
      "ci_passed" => 0.45,
      "lint_clean" => 0.18,
      "tests_pass" => 0.18,
      "iterations" => 0.09,
      "mutation_kill_rate" => MUTATION_KILL_RATE_WEIGHT
    },
    "performance_regression" => {
      "focus_resolved" => 0.54,
      "iterations" => 0.18,
      "tests_pass" => 0.09,
      "lint_clean" => 0.09,
      "ci_passed" => 0.10
    },
    "review_feedback" => {
      "focus_resolved" => 0.54,
      "iterations" => 0.18,
      "lint_clean" => 0.09,
      "tests_pass" => 0.09,
      "mutation_kill_rate" => MUTATION_KILL_RATE_WEIGHT
    },
    "merge_conflict" => {
      "focus_resolved" => 0.63,
      "ci_passed" => 0.135,
      "iterations" => 0.135,
      "mutation_kill_rate" => MUTATION_KILL_RATE_WEIGHT
    },
    "conversation" => {
      "focus_resolved" => 0.54,
      "iterations" => 0.18,
      "lint_clean" => 0.09,
      "tests_pass" => 0.09,
      "mutation_kill_rate" => MUTATION_KILL_RATE_WEIGHT
    },
    "label_action" => {
      "focus_resolved" => 0.54,
      "iterations" => 0.18,
      "lint_clean" => 0.09,
      "tests_pass" => 0.09,
      "mutation_kill_rate" => MUTATION_KILL_RATE_WEIGHT
    },
    "issue_implementation" => {
      "focus_resolved" => 0.45,
      "ci_passed" => 0.135,
      "iterations" => 0.135,
      "lint_clean" => 0.09,
      "tests_pass" => 0.09,
      "mutation_kill_rate" => MUTATION_KILL_RATE_WEIGHT
    }
  }.freeze

  # Goal-specific weights for composite quality scoring.
  # Each goal type has different signals relevant to its output quality.
  GOAL_WEIGHTS = {
    "create_pr" => SCORE_WEIGHTS,
    "create_issue" => {
      "issue_created" => 0.40,
      "reaction_score" => 0.60
    },
    "review" => {
      "review_posted" => 0.40,
      "reaction_score" => 0.60
    },
    "enhance_issue" => {
      "comment_posted" => 0.30,
      "reaction_score" => 0.35,
      "author_replied" => 0.25,
      "question_count" => 0.10
    }
  }.freeze

  belongs_to :agent_run
  belongs_to :prompt_version, optional: true

  after_commit :invalidate_dashboard_overview_cache

  validates :metric_type, presence: true, inclusion: { in: METRIC_TYPES }
  validates :feedback_source, inclusion: { in: FEEDBACK_SOURCES }, allow_nil: true
  validates :source, presence: true, inclusion: { in: SOURCES }
  validates :composite_score,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },
    allow_nil: true
  validates :mutation_kill_rate,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },
    allow_nil: true
  validates :metric_type, uniqueness: { scope: :agent_run_id }

  scope :automated, -> { where(metric_type: "automated") }
  scope :human, -> { where(metric_type: "human") }
  scope :agent_run_source, -> { where(source: AGENT_RUN_SOURCE) }
  scope :scheduled_mutation_sweep, -> { where(source: SCHEDULED_MUTATION_SWEEP_SOURCE) }
  scope :by_prompt_version, ->(prompt_version_id) { where(prompt_version_id: prompt_version_id) }
  scope :by_project, ->(project_id) { joins(:agent_run).where(agent_runs: { project_id: project_id }) }
  scope :by_time_period, ->(start_date, end_date) { where(created_at: start_date..end_date) }
  scope :with_composite_score, -> { where.not(composite_score: nil) }
  scope :recent, -> { order(created_at: :desc) }
  scope :below_threshold, ->(metric_type, threshold) {
    if metric_type == "composite_score"
      where("quality_metrics.composite_score < ?", threshold)
    else
      where("jsonb_exists(quality_metrics.scores, ?)", metric_type)
        .where("(quality_metrics.scores ->> ?)::float < ?", metric_type, threshold)
    end
  }

  # Score degradation rate per review comment (0.1 = 10% penalty per comment).
  REVIEW_COMMENT_DEGRADATION = 0.1

  # Computes a review comment count score. More comments = lower quality.
  # Score degrades by REVIEW_COMMENT_DEGRADATION per comment, minimum 0.0.
  #
  # @param comment_count [Integer] number of review comments
  # @return [Float] score between 0.0 and 1.0
  def self.review_comment_count_score(comment_count)
    [ 1.0 - (comment_count.to_i * REVIEW_COMMENT_DEGRADATION), 0.0 ].max
  end

  # Computes a weighted average from a hash of scores using the given weights.
  # Scores without a defined weight are ignored.
  #
  # @param scores_hash [Hash{String => Numeric}] Score name to value mapping
  # @param weights [Hash{String => Numeric}] Weight definitions (defaults to SCORE_WEIGHTS)
  # @return [Float, nil] Weighted average (0.0..1.0), or nil if no weighted scores
  def self.weighted_average(scores_hash, weights: SCORE_WEIGHTS)
    return nil if scores_hash.blank?

    total_weight = 0.0
    weighted_sum = 0.0

    scores_hash.each do |key, value|
      weight = weights[key]
      next unless weight
      next if value.nil?

      total_weight += weight
      weighted_sum += weight * value.to_f
    end

    return nil if total_weight.zero?

    (weighted_sum / total_weight).round(4)
  end

  def self.weights_for(goal: "create_pr", focus: "general") # @spec FOCUSED-RUN-004
    goal_weights = GOAL_WEIGHTS.fetch(goal, SCORE_WEIGHTS)
    return goal_weights unless goal == "create_pr"

    FOCUS_WEIGHTS.fetch(focus.to_s, SCORE_WEIGHTS)
  end

  # Calculates composite score from individual scores using goal-specific weights.
  #
  # @return [Float, nil] Score between 0.0 and 1.0, or nil if no scores
  def calculate_composite_score
    goal = agent_run&.goal || "create_pr"
    focus = agent_run&.focus || "general"
    weights = self.class.weights_for(goal:, focus:)
    score_inputs = scores.to_h
    score_inputs["mutation_kill_rate"] = mutation_kill_rate unless mutation_kill_rate.nil?
    self.class.weighted_average(score_inputs, weights: weights)
  end

  # Calculates and persists the composite score.
  #
  # @return [Float, nil] The calculated composite score
  def calculate_composite_score!
    self.composite_score = calculate_composite_score
    save! if composite_score_changed?
    composite_score
  end

  private

  def invalidate_dashboard_overview_cache
    Rails.cache.delete(QualityMetrics::DashboardStats.overview_cache_key(agent_run.project_id))
  end
end
