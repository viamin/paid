# frozen_string_literal: true

class QualityGateThreshold < ApplicationRecord
  has_logidze
  SEVERITIES = %w[info warning critical].freeze
  METRIC_KEYS = %w[composite_score pr_created ci_passed pr_merged iterations lint_clean
                   tests_pass review_comment_count agent_rerun_count issue_created
                   reaction_score review_posted review_score].freeze

  belongs_to :project
  has_many :quality_gate_events, dependent: :destroy

  validates :metric_key, presence: true, inclusion: { in: METRIC_KEYS },
    uniqueness: { scope: :project_id }
  validates :severity, presence: true, inclusion: { in: SEVERITIES }
  validates :min_threshold,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },
    allow_nil: true
  validates :max_threshold,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },
    allow_nil: true
  validate :at_least_one_threshold

  scope :enabled, -> { where(enabled: true) }
  scope :for_metric, ->(key) { where(metric_key: key) }

  # Check whether a given score breaches this threshold.
  #
  # @param score [Numeric] the score to evaluate
  # @return [Boolean]
  def breached?(score)
    return false if score.nil?

    (min_threshold.present? && score < min_threshold) ||
      (max_threshold.present? && score > max_threshold)
  end

  # The threshold value that was breached (for event recording).
  #
  # @param score [Numeric]
  # @return [BigDecimal, nil]
  def breached_value(score)
    return nil unless breached?(score)

    if min_threshold.present? && score < min_threshold
      min_threshold
    else
      max_threshold
    end
  end

  private

  def at_least_one_threshold
    if min_threshold.blank? && max_threshold.blank?
      errors.add(:base, "at least one threshold (min or max) must be set")
    end
  end
end
