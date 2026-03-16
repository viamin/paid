# frozen_string_literal: true

class LlmModel < ApplicationRecord
  CATEGORIES = %w[general coding planning review].freeze
  PROVIDERS = %w[anthropic openai google mistral meta cohere].freeze

  has_many :model_selections, dependent: :restrict_with_error

  validates :model_id, presence: true, uniqueness: true
  validates :display_name, presence: true
  validates :provider, presence: true, length: { maximum: 50 }
  validates :category, presence: true, inclusion: { in: CATEGORIES }
  validates :capability_score, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 10 }, allow_nil: true
  validates :input_cost_per_million, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :output_cost_per_million, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  scope :active, -> { where(active: true) }
  scope :by_provider, ->(provider) { where(provider: provider) }
  scope :by_category, ->(category) { where(category: category) }
  scope :by_capability, -> { order(Arel.sql("capability_score DESC NULLS LAST")) }
  scope :affordable, ->(budget_cents, avg_tokens) {
    return active if budget_cents.nil?

    where(
      "((COALESCE(input_cost_per_million, 0) + COALESCE(output_cost_per_million, 0)) / 2.0 * :tokens / 1000000.0 * 100) <= :budget",
      tokens: avg_tokens,
      budget: budget_cents
    )
  }

  def estimated_cost(input_tokens, output_tokens)
    input_cost = (input_cost_per_million || 0) * BigDecimal(input_tokens.to_s) / BigDecimal("1000000")
    output_cost = (output_cost_per_million || 0) * BigDecimal(output_tokens.to_s) / BigDecimal("1000000")
    ((input_cost + output_cost) * 100).round.to_i
  end

  def self.default_for_task(category)
    active.by_category(category).by_capability.first || active.by_capability.first
  end

  def self.find_by_model_id(model_id)
    find_by(model_id: model_id)
  end
end
