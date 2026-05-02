# frozen_string_literal: true

# Circuit breaker for GitHub API availability.
#
# Tracks consecutive infrastructure failures (5xx, network errors) and
# transitions through closed → open → half_open states following the
# same pattern as ProviderState. A singleton row per endpoint allows
# the system to pause dispatching during GitHub outages.
class GithubHealthState < ApplicationRecord
  CIRCUIT_STATES = %w[closed open half_open].freeze
  DEFAULT_ENDPOINT = "api"
  DEFAULT_FAILURE_THRESHOLD = 5
  DEFAULT_RECOVERY_TIMEOUT = 300

  validates :endpoint, presence: true, length: { maximum: 50 }, uniqueness: true
  validates :circuit_state, presence: true, inclusion: { in: CIRCUIT_STATES }
  validates :failure_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :for_endpoint, ->(name) { where(endpoint: name) }

  # Returns the singleton state for the default GitHub API endpoint,
  # creating it if it does not exist.
  def self.current(endpoint: DEFAULT_ENDPOINT)
    find_or_create_by!(endpoint: endpoint)
  rescue ActiveRecord::RecordNotUnique
    find_by!(endpoint: endpoint)
  end

  # Returns true if GitHub is currently unavailable (circuit open).
  def self.github_available?(endpoint: DEFAULT_ENDPOINT)
    state = find_by(endpoint: endpoint)
    return true unless state

    !state.circuit_open?
  end

  # Checks recovery timeout, then returns true if GitHub is available.
  # Consolidates the check-then-query pattern used by multiple jobs.
  def self.github_available_with_recovery?(endpoint: DEFAULT_ENDPOINT)
    state = find_by(endpoint: endpoint)
    return true unless state

    state.check_circuit_recovery!
    !state.unavailable?
  end

  # Records an infrastructure failure and opens the circuit when the
  # threshold is reached.
  def record_failure!(threshold: DEFAULT_FAILURE_THRESHOLD, error_message: nil)
    with_lock do
      new_count = failure_count + 1
      attrs = { failure_count: new_count, last_error_message: error_message&.truncate(500) }

      if circuit_state == "half_open"
        attrs[:circuit_state] = "open"
        attrs[:circuit_opened_at] = Time.current

        Rails.logger.warn(
          message: "github_health.circuit_reopened",
          endpoint: endpoint,
          failure_count: new_count,
          last_error: error_message&.truncate(200)
        )
      elsif new_count >= threshold && circuit_state == "closed"
        attrs[:circuit_state] = "open"
        attrs[:circuit_opened_at] = Time.current

        Rails.logger.warn(
          message: "github_health.circuit_opened",
          endpoint: endpoint,
          failure_count: new_count,
          last_error: error_message&.truncate(200)
        )
      end

      update!(attrs)
    end
  end

  # Records a successful GitHub API call and resets the circuit.
  # Only half_open → closed transitions are allowed on success;
  # an in-flight success while circuit is open must not bypass the
  # recovery timeout.
  def record_success!
    with_lock do
      return if circuit_state == "closed" && failure_count.zero?
      return if circuit_open?

      was_half_open = circuit_half_open?

      update!(
        failure_count: 0,
        circuit_state: "closed",
        circuit_opened_at: nil,
        last_error_message: nil
      )

      if was_half_open
        Rails.logger.info(
          message: "github_health.circuit_closed",
          endpoint: endpoint
        )
      end
    end
  end

  # Transitions from open → half_open after the recovery timeout.
  #
  # @param timeout [Integer] Seconds to wait before attempting recovery
  # @return [Boolean] true if transitioned to half_open
  def check_circuit_recovery!(timeout: DEFAULT_RECOVERY_TIMEOUT)
    with_lock do
      return false unless circuit_state == "open"
      return false unless circuit_opened_at.present?
      return false unless circuit_opened_at + timeout.seconds <= Time.current

      update!(circuit_state: "half_open")

      Rails.logger.info(
        message: "github_health.circuit_half_open",
        endpoint: endpoint
      )
      true
    end
  end

  def circuit_open?
    circuit_state == "open"
  end

  def circuit_half_open?
    circuit_state == "half_open"
  end

  def circuit_closed?
    circuit_state == "closed"
  end

  # Returns true when dispatching should be paused.
  def unavailable?
    circuit_open?
  end
end
