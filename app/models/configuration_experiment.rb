# frozen_string_literal: true

require "zlib"

class ConfigurationExperiment < ApplicationRecord
  STATUSES = %w[draft running completed cancelled].freeze
  EXPERIMENT_TYPES = %w[agent_output llm_output quality_signal].freeze
  TRACKED_CONFIG_KEYS = %w[knowledge.token_budget knowledge.section_order].freeze
  MAX_VARIANTS = 3
  ANALYSIS_INTERVAL = AbTest::ANALYSIS_INTERVAL

  belongs_to :account, optional: true
  belongs_to :winner_variant, class_name: "ConfigurationExperimentVariant", optional: true

  has_many :configuration_experiment_variants, dependent: :destroy
  has_many :configuration_experiment_assignments, dependent: :destroy

  validates :name, presence: true, length: { maximum: 255 }
  validates :config_key, presence: true, length: { maximum: 255 }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :control_value, presence: true
  validates :experiment_type, presence: true, inclusion: { in: EXPERIMENT_TYPES }
  validates :min_samples_per_variant, numericality: { only_integer: true, greater_than_or_equal_to: 2 }
  validates :confidence_threshold, numericality: { greater_than: 0, less_than_or_equal_to: 1 }
  validates :traffic_percentage, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validate :variant_count_within_limit
  validate :winner_variant_belongs_to_experiment

  scope :draft, -> { where(status: "draft") }
  scope :running, -> { where(status: "running") }
  scope :completed, -> { where(status: "completed") }
  scope :cancelled, -> { where(status: "cancelled") }

  def self.active_for(config_key, project: nil, agent_run: nil)
    for_config_key(config_key, project: project).detect do |experiment|
      experiment.includes_traffic?(agent_run: agent_run, project: project)
    end
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
    errors.add(:base, "another configuration experiment is already running for this config key")
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
    configuration_experiment_variants.find_by(is_control: true)
  end

  def sufficient_samples?
    configuration_experiment_variants.all? { |v| v.sample_count >= min_samples_per_variant }
  end

  def includes_traffic?(agent_run: nil, project: nil)
    return false if traffic_percentage.zero?
    return true if traffic_percentage == 100

    rollout_subject = agent_run || project
    return false unless rollout_subject

    Zlib.crc32("#{id}:#{rollout_subject.class.name}:#{rollout_subject.id}") % 100 < traffic_percentage
  end

  def cached_or_compute_analysis(persist: true)
    current_key = samples_key
    if cached_analysis.present?
      return deserialize_analysis if analysis_samples_key == current_key
      return deserialize_analysis unless persist
    end

    return nil unless persist

    ConfigurationExperiments::Analyze.call(configuration_experiment: self).tap { |result| persist_analysis!(result, current_key) }
  end

  private

  CACHE_BUCKET_SIZE = ANALYSIS_INTERVAL

  private_class_method def self.for_config_key(config_key, project:)
    candidates = running.where(config_key: config_key)
    return candidates.where(account_id: nil).order(:id) unless project

    candidates
      .where(account_id: [ project.account_id, nil ])
      .order(:id)
      .sort_by { |experiment| [ experiment.account_id == project.account_id ? 0 : 1, experiment.id ] }
  end

  def raise_invalid_status!(action)
    errors.add(:base, "cannot #{action} an experiment that is #{status}")
    raise ActiveRecord::RecordInvalid, self
  end

  def samples_key
    total_samples = configuration_experiment_variants.sum(&:sample_count)
    total_bucket = (total_samples / CACHE_BUCKET_SIZE) * CACHE_BUCKET_SIZE

    variant_buckets = configuration_experiment_variants
      .sort_by(&:id)
      .map { |v| "#{v.id}:#{(v.sample_count / CACHE_BUCKET_SIZE) * CACHE_BUCKET_SIZE}" }
      .join(",")

    "total:#{total_bucket}|#{variant_buckets}"
  end

  def persist_analysis!(result, key)
    update_columns(
      cached_analysis: {
        status: result.status.to_s,
        confidence: result.confidence&.to_f,
        improvement: result.improvement&.to_f,
        winner_id: result.winner&.id
      },
      analysis_samples_key: key
    )
  end

  def deserialize_analysis
    data = cached_analysis.symbolize_keys
    winner = data[:winner_id] ? configuration_experiment_variants.find_by(id: data[:winner_id]) : nil
    ConfigurationExperiments::Analyze::Result.new(
      status: data[:status]&.to_sym,
      winner: winner,
      confidence: data[:confidence],
      improvement: data[:improvement]
    )
  end

  def variant_count_within_limit
    return if configuration_experiment_variants.size <= MAX_VARIANTS + 1

    errors.add(:configuration_experiment_variants, "cannot have more than #{MAX_VARIANTS} variants plus control")
  end

  def winner_variant_belongs_to_experiment
    return if winner_variant.nil?
    return if winner_variant.configuration_experiment_id == id

    errors.add(:winner_variant, "must belong to this configuration experiment")
  end
end
