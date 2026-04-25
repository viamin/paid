# frozen_string_literal: true

class LlmOutputMetric < ApplicationRecord
  OUTPUT_TYPES = %w[pr_description issue_title decision_record].freeze
  SOURCE_TYPES = %w[PullRequest Issue DecisionRecord].freeze
  METRIC_TYPES = %w[automated human].freeze

  # Weights for composite quality scoring by output type.
  OUTPUT_WEIGHTS = {
    "pr_description" => {
      "description_edited" => 0.50,
      "description_length_ratio" => 0.20,
      "pr_reaction" => 0.30
    },
    "issue_title" => {
      "title_edited" => 0.60,
      "issue_reaction" => 0.40
    },
    "decision_record" => {
      "record_kept" => 0.60,
      "tag_count" => 0.40
    }
  }.freeze

  include TenantScoped

  belongs_to :project
  belongs_to :prompt_version, optional: true

  validates :output_type, presence: true, inclusion: { in: OUTPUT_TYPES }
  validates :prompt_slug, presence: true
  validates :source_id, presence: true
  validates :source_type, presence: true, inclusion: { in: SOURCE_TYPES }
  validates :source_id, uniqueness: { scope: [ :project_id, :output_type, :source_type ] }
  validates :composite_score,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },
    allow_nil: true

  scope :by_output_type, ->(type) { where(output_type: type) }
  scope :by_prompt_slug, ->(slug) { where(prompt_slug: slug) }
  scope :by_project, ->(project_id) { where(project_id: project_id) }
  scope :by_time_period, ->(start_date, end_date) { where(created_at: start_date..end_date) }
  scope :with_composite_score, -> { where.not(composite_score: nil) }
  scope :recent, -> { order(created_at: :desc) }
  scope :for_source, ->(source_type, source_id) { where(source_type: source_type, source_id: source_id) }

  def calculate_composite_score
    weights = OUTPUT_WEIGHTS.fetch(output_type, {})
    self.class.weighted_average(scores, weights: weights)
  end

  def calculate_composite_score!
    self.composite_score = calculate_composite_score
    save! if composite_score_changed?
    composite_score
  end

  def self.weighted_average(scores_hash, weights:)
    return nil if scores_hash.blank?

    total_weight = 0.0
    weighted_sum = 0.0

    scores_hash.each do |key, value|
      weight = weights[key]
      next unless weight

      total_weight += weight
      weighted_sum += weight * value.to_f
    end

    return nil if total_weight.zero?

    (weighted_sum / total_weight).round(4)
  end
end
