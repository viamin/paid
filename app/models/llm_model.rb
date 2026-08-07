# frozen_string_literal: true

class LlmModel < ApplicationRecord
  has_logidze
  CATEGORIES = %w[general coding planning review].freeze
  PROVIDERS = %w[anthropic openai google mistral meta cohere].freeze
  TIERS = %w[low mid high].freeze
  PRICING_TIERS = %w[paid free freemium].freeze
  DATA_TRAINING_RISKS = %w[none possible unknown].freeze
  CATALOG_SOURCES = %w[seeded openrouter_sync manual].freeze

  belongs_to :free_variant_of, class_name: "LlmModel", optional: true
  has_many :model_selections, dependent: :restrict_with_error
  has_many :configuration_bundles, dependent: :nullify

  validates :model_id, presence: true, uniqueness: true
  validates :display_name, presence: true
  validates :provider, presence: true, length: { maximum: 50 }
  validates :category, presence: true, inclusion: { in: CATEGORIES }
  validates :tier, inclusion: { in: TIERS }, allow_nil: true
  validates :pricing_tier, inclusion: { in: PRICING_TIERS }
  validates :data_training_risk, inclusion: { in: DATA_TRAINING_RISKS }, allow_nil: true
  validates :catalog_source, inclusion: { in: CATALOG_SOURCES }
  validates :capability_score, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 10 }, allow_nil: true
  validates :input_cost_per_million, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :output_cost_per_million, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  scope :active, -> { where(active: true) }
  scope :by_provider, ->(provider) { where(provider: provider) }
  scope :by_category, ->(category) { where(category: category) }
  scope :by_capability, -> { order(Arel.sql("capability_score DESC NULLS LAST")) }
  scope :by_tier, ->(tier) { where(tier: tier) }
  scope :by_pricing_tier, ->(pricing_tier) { where(pricing_tier: pricing_tier) }
  scope :free, -> { by_pricing_tier("free") }
  scope :paid, -> { by_pricing_tier("paid") }
  scope :openrouter_synced, -> { where(catalog_source: "openrouter_sync") }
  scope :openrouter_synced_free, -> { free.openrouter_synced }
  # Catalog rows that are NOT OpenRouter-synced free variants. First-party
  # drift detection compares the seeded catalog against the RubyLLM registry;
  # OpenRouter free models are sourced and lifecycle-managed by FreeModels::Sync
  # against the OpenRouter catalog, so excluding them avoids false-positive
  # retirement alerts.
  scope :excluding_openrouter_synced_free, -> {
    where("NOT (catalog_source = ? AND pricing_tier = ?)", "openrouter_sync", "free")
  }
  scope :affordable, ->(budget_cents, avg_tokens) {
    return active if budget_cents.nil?

    # Always filter to active models, then exclude unknown pricing
    active
      .where.not(input_cost_per_million: nil)
      .where.not(output_cost_per_million: nil)
      .where(
        "((input_cost_per_million + output_cost_per_million) / 2 * :tokens / 1000000 * 100) <= :budget",
        tokens: avg_tokens,
        budget: budget_cents
      )
  }

  def estimated_cost(input_tokens, output_tokens)
    input_cost = (input_cost_per_million || 0) * BigDecimal(input_tokens.to_s) / BigDecimal("1000000")
    output_cost = (output_cost_per_million || 0) * BigDecimal(output_tokens.to_s) / BigDecimal("1000000")
    ((input_cost + output_cost) * 100).round.to_i
  end

  def free?
    pricing_tier == "free"
  end

  def below_quality_bar?
    ActiveModel::Type::Boolean.new.cast(metadata["below_quality_bar"])
  end

  def reasoning_supported?
    ActiveModel::Type::Boolean.new.cast(metadata["supports_reasoning"]) ||
      Array(metadata["supported_parameters"]).map(&:to_s).include?("reasoning")
  end

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  def self.default_for_task(category)
    active.by_category(category).by_capability.first || active.by_capability.first
  end

  def self.find_by_model_id(model_id)
    find_by(model_id: model_id)
  end

  # Idempotently registers a direct-outbound runner's user-entered model id in
  # the catalog with catalog_source: "manual". Used by Runner to keep the
  # seeded/synced catalog as the source of truth for automated selection while
  # still letting users point runners at newly released models before a seed
  # update lands. Returns the existing or newly-created LlmModel.
  #
  # The bare model_id is preferred (no provider prefix) so future lookups using
  # either the qualified or bare form resolve to the same row, matching how
  # Models::SeedKnownModels stores seeded entries.
  def self.upsert_manual_catalog_entry(model_id:, provider:)
    existing = find_by(model_id: model_id)
    return existing if existing

    create!(
      model_id: model_id,
      display_name: model_id.to_s.tr("_", " ").split.map(&:capitalize).join(" ").presence || model_id.to_s,
      provider: provider,
      category: "coding",
      tier: "mid",
      active: true,
      catalog_source: "manual",
      pricing_tier: "paid"
    )
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    find_by!(model_id: model_id)
  end
end
