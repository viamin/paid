# frozen_string_literal: true

class ProviderState < ApplicationRecord
  CIRCUIT_STATES = %w[closed open half_open].freeze

  belongs_to :user

  validates :provider_name, presence: true, length: { maximum: 50 }
  validates :circuit_state, presence: true, inclusion: { in: CIRCUIT_STATES }
  validates :failure_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :for_provider, ->(name) { where(provider_name: name) }

  # Returns true if the provider is currently rate limited.
  def rate_limited?
    rate_limited_until.present? && rate_limited_until > Time.current
  end

  # Marks the provider as rate limited until the given time.
  #
  # @param reset_at [Time, nil] When the rate limit resets. Defaults to 60 seconds from now.
  def mark_rate_limited!(reset_at: nil)
    reset_at ||= 60.seconds.from_now
    update!(rate_limited_until: reset_at)
  end

  # Clears the rate limit for this provider.
  def clear_rate_limit!
    update!(rate_limited_until: nil)
  end

  # Records a failure and opens the circuit if threshold is reached.
  #
  # @param threshold [Integer] Number of failures before opening the circuit
  def record_failure!(threshold: 5)
    with_lock do
      new_count = failure_count + 1

      if new_count >= threshold && circuit_state == "closed"
        update!(
          failure_count: new_count,
          circuit_state: "open",
          circuit_opened_at: Time.current
        )
      else
        update!(failure_count: new_count)
      end
    end
  end

  # Records a success and resets the circuit breaker.
  def record_success!
    update!(
      failure_count: 0,
      circuit_state: "closed",
      circuit_opened_at: nil,
      rate_limited_until: nil
    )
  end

  # Checks if the circuit should transition from open to half_open after timeout.
  #
  # @param timeout [Integer] Seconds to wait before trying half_open
  # @return [Boolean] true if transitioned to half_open
  def check_circuit_recovery!(timeout: 300)
    return false unless circuit_state == "open"
    return false unless circuit_opened_at.present?
    return false unless circuit_opened_at + timeout.seconds <= Time.current

    update!(circuit_state: "half_open")
    true
  end

  # Returns true if the circuit is open (provider should not be used).
  def circuit_open?
    circuit_state == "open"
  end

  # Returns true if the circuit is half open (can try one request).
  def circuit_half_open?
    circuit_state == "half_open"
  end

  # Returns true if the circuit is closed (provider is healthy).
  def circuit_closed?
    circuit_state == "closed"
  end

  # Returns true if the provider is currently unavailable (rate limited or circuit open).
  def unavailable?
    rate_limited? || circuit_open?
  end
end
