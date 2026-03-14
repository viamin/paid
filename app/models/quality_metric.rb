# frozen_string_literal: true

class QualityMetric < ApplicationRecord
  # Composite score weights
  WEIGHTS = {
    ci_passed: 0.25,
    pr_merged: 0.25,
    iterations: 0.20,
    lint_clean: 0.15,
    review_comments: 0.15
  }.freeze

  belongs_to :agent_run
  belongs_to :prompt_version, optional: true

  validates :agent_run_id, uniqueness: true
  validates :quality_score, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
  validates :human_vote, inclusion: { in: [ -1, 0, 1 ] }, allow_nil: true

  scope :recent, -> { order(created_at: :desc) }
  scope :with_scores, -> { where.not(quality_score: nil) }

  def calculate_composite_score!
    weighted_sum = 0.0
    weight_sum = 0.0

    unless ci_passed.nil?
      weighted_sum += (ci_passed ? 1.0 : 0.0) * WEIGHTS[:ci_passed]
      weight_sum += WEIGHTS[:ci_passed]
    end

    unless pr_merged.nil?
      weighted_sum += (pr_merged ? 1.0 : 0.0) * WEIGHTS[:pr_merged]
      weight_sum += WEIGHTS[:pr_merged]
    end

    if iterations_to_complete && iterations_to_complete > 0
      iteration_score = [ 1.0 - ((iterations_to_complete - 1) * 0.1), 0.0 ].max
      weighted_sum += iteration_score * WEIGHTS[:iterations]
      weight_sum += WEIGHTS[:iterations]
    end

    if lint_errors
      weighted_sum += (lint_errors.zero? ? 1.0 : [ 1.0 - (lint_errors * 0.1), 0.0 ].max) * WEIGHTS[:lint_clean]
      weight_sum += WEIGHTS[:lint_clean]
    end

    if review_comments_count && review_comments_count >= 0
      comment_score = [ 1.0 - (review_comments_count * 0.05), 0.0 ].max
      weighted_sum += comment_score * WEIGHTS[:review_comments]
      weight_sum += WEIGHTS[:review_comments]
    end

    self.quality_score = weight_sum.positive? ? (weighted_sum / weight_sum).round(2) : nil
    save!
  end
end
