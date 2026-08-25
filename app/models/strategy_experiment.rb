# frozen_string_literal: true

require "zlib"

class StrategyExperiment < ApplicationRecord
  STATUSES = %w[draft running completed cancelled].freeze
  STRATEGY_NAMES = %w[
    auto_pick
    auto_continue
    auto_review
    auto_merge
    review_settings
    quality_gate
    execution_timeouts
    retry_policies
    agent_settings
    feature_orchestration
    provider_resolution
  ].freeze
  MAX_VARIANTS = 3
  ANALYSIS_INTERVAL = AbTest::ANALYSIS_INTERVAL

  belongs_to :account
  belongs_to :winner_variant, class_name: "StrategyExperimentVariant", optional: true

  has_many :strategy_experiment_variants, dependent: :destroy
  has_many :strategy_experiment_assignments, dependent: :destroy

  validates :name, presence: true, length: { maximum: 255 }
  validates :strategy_name, presence: true, inclusion: { in: STRATEGY_NAMES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :control_config, presence: true
  validates :min_samples_per_variant, numericality: { only_integer: true, greater_than_or_equal_to: 2 }
  validates :confidence_threshold, numericality: { greater_than: 0, less_than_or_equal_to: 1 }
  validates :traffic_percentage, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validate :variant_count_within_limit
  validate :winner_variant_belongs_to_experiment

  scope :draft, -> { where(status: "draft") }
  scope :running, -> { where(status: "running") }
  scope :completed, -> { where(status: "completed") }
  scope :cancelled, -> { where(status: "cancelled") }

  include Experiments::AnalysisCache
  analysis_cache(
    analyzer_class: StrategyExperiments::Analyze,
    variants_association: :strategy_experiment_variants,
    call_keyword: :strategy_experiment
  )

  def self.active_for(strategy_name, account:, agent_run: nil)
    experiment = running
      .where(strategy_name: strategy_name, account: account)
      .order(:id)
      .first
    return nil unless experiment
    return nil unless experiment.includes_traffic?(agent_run: agent_run)

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
    errors.add(:base, "another strategy experiment is already running for this strategy")
    raise ActiveRecord::RecordInvalid, self
  end

  def complete!(winner: nil)
    with_lock do
      reload
      raise_invalid_status!("complete") unless running?

      update!(status: "completed", completed_at: Time.current, winner_variant: winner)
    end
  end

  def cancel!
    with_lock do
      reload
      unless %w[draft running].include?(status)
        raise_invalid_status!("cancel")
      end

      update!(status: "cancelled", completed_at: Time.current)
    end
  end

  def control_variant
    strategy_experiment_variants.find_by(is_control: true)
  end

  def sufficient_samples?
    strategy_experiment_variants.all? { |v| v.sample_count >= min_samples_per_variant }
  end

  def includes_traffic?(agent_run: nil)
    return false if traffic_percentage.zero?
    return true if traffic_percentage == 100

    return false unless agent_run

    Zlib.crc32("#{id}:#{agent_run.class.name}:#{agent_run.id}") % 100 < traffic_percentage
  end

  private

  def raise_invalid_status!(action)
    errors.add(:base, "cannot #{action} an experiment that is #{status}")
    raise ActiveRecord::RecordInvalid, self
  end

  def samples_key
    total_samples = strategy_experiment_variants.sum(&:sample_count)
    total_bucket = (total_samples / Experiments::AnalysisCache::CACHE_BUCKET_SIZE) * Experiments::AnalysisCache::CACHE_BUCKET_SIZE

    variant_buckets = strategy_experiment_variants
      .sort_by(&:id)
      .map { |v| "#{v.id}:#{(v.sample_count / Experiments::AnalysisCache::CACHE_BUCKET_SIZE) * Experiments::AnalysisCache::CACHE_BUCKET_SIZE}" }
      .join(",")

    "total:#{total_bucket}|#{variant_buckets}"
  end

  def variant_count_within_limit
    return if strategy_experiment_variants.size <= MAX_VARIANTS + 1

    errors.add(:strategy_experiment_variants, "cannot have more than #{MAX_VARIANTS} variants plus control")
  end

  def winner_variant_belongs_to_experiment
    return if winner_variant.nil?
    return if winner_variant.strategy_experiment_id == id

    errors.add(:winner_variant, "must belong to this strategy experiment")
  end
end
