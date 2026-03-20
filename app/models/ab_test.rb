# frozen_string_literal: true

class AbTest < ApplicationRecord
  STATUSES = %w[draft running completed cancelled].freeze
  MAX_VARIANTS = 3

  belongs_to :prompt
  belongs_to :control_version, class_name: "PromptVersion"
  belongs_to :winner_variant, class_name: "AbTestVariant", optional: true

  has_many :ab_test_variants, dependent: :destroy
  has_many :ab_test_assignments, dependent: :destroy

  validates :name, presence: true, length: { maximum: 255 }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :min_samples_per_variant, numericality: { only_integer: true, greater_than_or_equal_to: 2 }
  validates :confidence_threshold, numericality: { greater_than: 0, less_than_or_equal_to: 1 }
  validate :variant_count_within_limit
  validate :control_version_belongs_to_prompt
  validate :winner_variant_belongs_to_test

  scope :draft, -> { where(status: "draft") }
  scope :running, -> { where(status: "running") }
  scope :completed, -> { where(status: "completed") }
  scope :cancelled, -> { where(status: "cancelled") }
  scope :active, -> { where(status: %w[draft running]) }

  def draft?
    status == "draft"
  end

  def running?
    status == "running"
  end

  def completed?
    status == "completed"
  end

  def cancelled?
    status == "cancelled"
  end

  def start!
    with_lock do
      reload
      unless draft?
        errors.add(:base, "cannot start a test that is #{status}")
        raise ActiveRecord::RecordInvalid, self
      end
      update!(status: "running", started_at: Time.current)
    end
  rescue ActiveRecord::RecordNotUnique
    errors.add(:base, "another test is already running for this prompt")
    raise ActiveRecord::RecordInvalid, self
  end

  def complete!(winner: nil)
    with_lock do
      reload
      unless running?
        errors.add(:base, "cannot complete a test that is #{status}")
        raise ActiveRecord::RecordInvalid, self
      end
      update!(status: "completed", completed_at: Time.current, winner_variant: winner)
    end
  end

  def cancel!
    with_lock do
      reload
      unless %w[draft running].include?(status)
        errors.add(:base, "cannot cancel a test that is #{status}")
        raise ActiveRecord::RecordInvalid, self
      end
      update!(status: "cancelled", completed_at: Time.current)
    end
  end

  def control_variant
    ab_test_variants.find_by(is_control: true)
  end

  def non_control_variants
    ab_test_variants.where(is_control: false)
  end

  def sufficient_samples?
    ab_test_variants.all? { |v| v.sample_count >= min_samples_per_variant }
  end

  # Returns cached analysis when fresh, otherwise recomputes via AbTests::Analyze.
  # Pass persist: true (default) from write paths (e.g. RecordResult) to update the DB cache.
  # Pass persist: false from read paths (e.g. controller show) to keep GET requests read-only
  # and return the last persisted result rather than recomputing. Returns nil on cache miss
  # when persist: false — the write path (RecordResult) will populate the cache.
  def cached_or_compute_analysis(persist: true)
    current_key = samples_key
    if cached_analysis.present?
      return deserialize_analysis if analysis_samples_key == current_key
      # On read paths, return the stale cached result rather than triggering an
      # expensive recomputation — the write path (RecordResult) will refresh
      # the cache at the next analysis interval.
      return deserialize_analysis unless persist
    end

    # Read paths never trigger expensive recomputation on cache miss.
    return nil unless persist

    AbTests::Analyze.call(ab_test: self).tap { |result| persist_analysis!(result, current_key) }
  end

  private

  # Bucket sample counts to the same interval used by RecordResult's analysis
  # throttle so cache freshness aligns with write-path recomputation cadence.
  CACHE_BUCKET_SIZE = AbTests::RecordResult::ANALYSIS_INTERVAL

  def samples_key
    total_samples = ab_test_variants.sum(&:sample_count)
    total_bucket  = (total_samples / CACHE_BUCKET_SIZE) * CACHE_BUCKET_SIZE

    variant_buckets = ab_test_variants
                      .sort_by(&:id)
                      .map { |v| "#{v.id}:#{(v.sample_count / CACHE_BUCKET_SIZE) * CACHE_BUCKET_SIZE}" }
                      .join(",")

    "total:#{total_bucket}|#{variant_buckets}"
  end

  def persist_analysis!(result, key)
    serialized = {
      status: result.status.to_s,
      confidence: result.confidence&.to_f,
      improvement: result.improvement&.to_f,
      winner_id: result.winner&.id
    }
    update_columns(cached_analysis: serialized, analysis_samples_key: key)
  end

  def deserialize_analysis
    data = cached_analysis.symbolize_keys
    winner = data[:winner_id] ? ab_test_variants.find_by(id: data[:winner_id]) : nil
    AbTests::Analyze::Result.new(
      status: data[:status]&.to_sym,
      winner: winner,
      confidence: data[:confidence],
      improvement: data[:improvement]
    )
  end

  def variant_count_within_limit
    return if ab_test_variants.size <= MAX_VARIANTS + 1 # +1 for control

    errors.add(:ab_test_variants, "cannot have more than #{MAX_VARIANTS} variants plus control")
  end

  def control_version_belongs_to_prompt
    return if control_version.nil? || prompt.nil?
    return if control_version.prompt_id == prompt_id

    errors.add(:control_version, "must belong to the same prompt")
  end

  def winner_variant_belongs_to_test
    return if winner_variant.nil?
    return if winner_variant.ab_test_id == id

    errors.add(:winner_variant, "must belong to this A/B test")
  end
end
