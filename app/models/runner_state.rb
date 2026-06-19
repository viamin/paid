# frozen_string_literal: true

require "set"

class RunnerState < ApplicationRecord
  CIRCUIT_STATES = %w[closed open half_open].freeze
  DEFAULT_FAILURE_THRESHOLD = 5
  DEFAULT_RECOVERY_TIMEOUT = 300
  DEFAULT_HALF_OPEN_SUCCESS_THRESHOLD = 3
  DEFAULT_HALF_OPEN_FAILURE_THRESHOLD = 2
  DEFAULT_MAX_FAILURE_COUNT = 100

  belongs_to :user

  validates :runner_name, presence: true, length: { maximum: 50 }
  validates :circuit_state, presence: true, inclusion: { in: CIRCUIT_STATES }
  validates :failure_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :half_open_success_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :half_open_failure_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :for_runner, ->(name) { where(runner_name: name) }

  # Returns true if the runner is currently rate limited.
  def rate_limited?
    rate_limited_until.present? && rate_limited_until > Time.current
  end

  # Marks the runner as rate limited until the given time.
  #
  # @param reset_at [Time, nil] When the rate limit resets. Defaults to 60 seconds from now.
  def mark_rate_limited!(reset_at: nil)
    reset_at ||= 60.seconds.from_now
    update!(rate_limited_until: reset_at)
  end

  # Clears the rate limit for this runner.
  def clear_rate_limit!
    update!(rate_limited_until: nil)
  end

  # Per-model rate-limit tracking for runners that support model rotation
  # (e.g. openrouter_free). The metadata jsonb column stores
  # `rate_limited_models` as `{ "model_id" => "reset_at_iso8601" }`. Entries
  # whose reset_at is in the past are pruned on read so rotation only sees
  # currently active windows.
  RATE_LIMITED_MODELS_METADATA_KEY = "rate_limited_models"

  # Returns the set of model ids that currently have an active per-model
  # rate-limit window. Stale entries (reset_at in the past) are dropped.
  def rate_limited_model_ids
    raw = metadata.is_a?(Hash) ? metadata[RATE_LIMITED_MODELS_METADATA_KEY] : nil
    return Set.new unless raw.is_a?(Hash)

    now = Time.current
    raw.each_with_object(Set.new) do |(model_id, reset_at), set|
      next if model_id.blank?
      next unless reset_at.present?

      parsed =
        begin
          Time.iso8601(reset_at.to_s)
        rescue ArgumentError
          nil
        end
      next if parsed.nil? || parsed <= now

      set << model_id.to_s
    end
  end

  # Returns true when the given model id has an active per-model rate-limit
  # window on this runner.
  def rate_limited_model?(model_id)
    return false if model_id.blank?

    rate_limited_model_ids.include?(model_id.to_s)
  end

  # Marks the given model as rate-limited on this runner until `reset_at`.
  # Persists the per-model entry to metadata and also clears any stale
  # entries whose reset windows have already expired.
  #
  # @param model_id [String] The model id to mark as rate-limited.
  # @param reset_at [Time, nil] When the model's rate limit resets.
  def mark_model_rate_limited!(model_id, reset_at: nil)
    return if model_id.blank?

    reset_at ||= 60.seconds.from_now
    with_lock do
      current = rate_limited_models_metadata
      current[model_id.to_s] = reset_at.iso8601
      update!(metadata: metadata.merge(RATE_LIMITED_MODELS_METADATA_KEY => current))
    end
  end

  # Clears the per-model rate-limit window for the given model id. Pass nil
  # to clear every per-model rate-limit entry (used when the runner succeeds
  # and we want to forget all known model windows).
  def clear_model_rate_limit!(model_id = nil)
    with_lock do
      if model_id.nil?
        next_metadata = metadata.dup
        next_metadata.delete(RATE_LIMITED_MODELS_METADATA_KEY)
        update!(metadata: next_metadata)
      else
        current = rate_limited_models_metadata
        return unless current.key?(model_id.to_s)

        current.delete(model_id.to_s)
        update!(metadata: metadata.merge(RATE_LIMITED_MODELS_METADATA_KEY => current))
      end
    end
  end

  # Records a failure and opens the circuit if threshold is reached.
  #
  # @param threshold [Integer] Number of failures before opening the circuit
  def record_failure!(threshold: DEFAULT_FAILURE_THRESHOLD, decay_window: DEFAULT_RECOVERY_TIMEOUT,
    half_open_failure_threshold: DEFAULT_HALF_OPEN_FAILURE_THRESHOLD)
    with_lock do
      now = Time.current
      new_count = [ decayed_failure_count(now:, decay_window:) + 1, max_failure_count(threshold) ].min
      attrs = { failure_count: new_count, last_failure_at: now }

      if circuit_half_open?
        new_half_open_failure_count = half_open_failure_count.to_i + 1
        attrs[:half_open_success_count] = 0

        if new_half_open_failure_count >= half_open_failure_threshold
          attrs[:circuit_state] = "open"
          attrs[:circuit_opened_at] = now
          attrs[:half_open_failure_count] = 0
        else
          attrs[:half_open_failure_count] = new_half_open_failure_count
        end
      elsif new_count >= threshold && circuit_closed?
        attrs[:circuit_state] = "open"
        attrs[:circuit_opened_at] = now
        attrs[:half_open_success_count] = 0
        attrs[:half_open_failure_count] = 0
      end

      update!(attrs)
    end
  end

  # Records a success and resets the circuit breaker.
  #
  # @param half_open_success_threshold [Integer] Consecutive half-open successes required to close the circuit.
  # @param force_close [Boolean] When true (explicit operator/test health checks), immediately close the circuit
  #   regardless of its current state instead of waiting on the recovery timeout or half-open success streak.
  def record_success!(half_open_success_threshold: DEFAULT_HALF_OPEN_SUCCESS_THRESHOLD, force_close: false)
    with_lock do
      unless force_close
        return if circuit_open?

        if circuit_half_open?
          new_half_open_success_count = half_open_success_count.to_i + 1

          if new_half_open_success_count < half_open_success_threshold
            update!(
              half_open_success_count: new_half_open_success_count,
              half_open_failure_count: 0,
              rate_limited_until: nil
            )
            return
          end
        elsif failure_count.zero? && rate_limited_until.blank?
          return
        end
      end

      update!(
        failure_count: 0,
        circuit_state: "closed",
        circuit_opened_at: nil,
        rate_limited_until: nil,
        last_failure_at: nil,
        half_open_success_count: 0,
        half_open_failure_count: 0,
        metadata: metadata.merge(RATE_LIMITED_MODELS_METADATA_KEY => {})
      )
    end
  end

  # Checks if the circuit should transition from open to half_open after timeout.
  #
  # @param timeout [Integer] Seconds to wait before trying half_open
  # @return [Boolean] true if transitioned to half_open
  def check_circuit_recovery!(timeout: DEFAULT_RECOVERY_TIMEOUT)
    with_lock do
      return false unless circuit_state == "open"
      return false unless circuit_opened_at.present?
      return false unless circuit_opened_at + timeout.seconds <= Time.current

      update!(
        circuit_state: "half_open",
        rate_limited_until: nil,
        failure_count: decayed_failure_count(now: Time.current, decay_window: timeout),
        half_open_success_count: 0,
        half_open_failure_count: 0
      )
      true
    end
  end

  # Returns true if the circuit is open (runner should not be used).
  def circuit_open?
    circuit_state == "open"
  end

  # Returns true if the circuit is half open (can try one request).
  def circuit_half_open?
    circuit_state == "half_open"
  end

  # Returns true if the circuit is closed (runner is healthy).
  def circuit_closed?
    circuit_state == "closed"
  end

  # Returns true if the runner is currently unavailable (rate limited or circuit open).
  def unavailable?
    rate_limited? || circuit_open?
  end

  def provider_name
    runner_name
  end

  def provider_name=(value)
    self.runner_name = value
  end

  private

  def rate_limited_models_metadata
    raw = metadata.is_a?(Hash) ? metadata[RATE_LIMITED_MODELS_METADATA_KEY] : nil
    raw.is_a?(Hash) ? raw.dup : {}
  end

  def decayed_failure_count(now:, decay_window:)
    return failure_count if last_failure_at.blank? || decay_window.to_i <= 0

    elapsed_windows = ((now - last_failure_at) / decay_window.seconds).floor
    return failure_count if elapsed_windows <= 0

    failure_count >> elapsed_windows
  end

  def max_failure_count(threshold)
    [ threshold * 10, DEFAULT_MAX_FAILURE_COUNT ].max
  end
end
