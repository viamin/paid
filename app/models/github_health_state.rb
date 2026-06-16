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
  GITHUB_TOKEN_ENDPOINT_PREFIX = "github_token".freeze
  GITHUB_INSTALLATION_ENDPOINT_PREFIX = "github_installation".freeze
  DEFAULT_FAILURE_THRESHOLD = 5
  DEFAULT_RECOVERY_TIMEOUT = 300

  validates :endpoint, presence: true, length: { maximum: 50 }, uniqueness: true
  validates :circuit_state, presence: true, inclusion: { in: CIRCUIT_STATES }
  validates :failure_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :for_endpoint, ->(name) { where(endpoint: name) }

  def self.endpoint_for_github_token(github_token_id)
    "#{GITHUB_TOKEN_ENDPOINT_PREFIX}:#{github_token_id}"
  end

  def self.endpoint_for_github_installation(github_installation_id)
    "#{GITHUB_INSTALLATION_ENDPOINT_PREFIX}:#{github_installation_id}"
  end

  # Returns the singleton state for the default GitHub API endpoint,
  # creating it if it does not exist.
  def self.current(endpoint: DEFAULT_ENDPOINT)
    find_or_create_by!(endpoint: endpoint)
  rescue ActiveRecord::RecordNotUnique
    find_by!(endpoint: endpoint)
  end

  # Returns true if GitHub is currently available. Treats both an open
  # circuit (infrastructure failures) and an active rate-limit window as
  # unavailable so callers can pause dispatching uniformly.
  def self.github_available?(endpoint: DEFAULT_ENDPOINT)
    state = find_by(endpoint: endpoint)
    return true unless state

    !state.unavailable?
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
      return if circuit_state == "closed" && failure_count.zero? && rate_limited_until.blank?
      return if circuit_open?

      was_half_open = circuit_half_open?

      update!(
        failure_count: 0,
        circuit_state: "closed",
        circuit_opened_at: nil,
        last_error_message: nil,
        rate_limited_until: nil
      )

      if was_half_open
        Rails.logger.info(
          message: "github_health.circuit_closed",
          endpoint: endpoint
        )
      end
    end
  end

  # Records a GitHub rate-limit response and persists the reset time so
  # the queue scheduler will pause dispatching until the limit resets.
  # Also captures the last-observed quota figures so they stay visible on
  # the dashboard while the limit window is in effect. Best-effort:
  # callers should not let persistence errors mask the original
  # rate-limit exception.
  #
  # @param reset_at [Time, nil] When the rate limit resets. Defaults to 60 seconds from now.
  # @param remaining [Integer, nil] Remaining requests reported by GitHub.
  # @param limit [Integer, nil] Total hourly request limit reported by GitHub.
  def mark_rate_limited!(reset_at: nil, remaining: nil, limit: nil)
    reset_at ||= 60.seconds.from_now
    with_lock do
      update!(
        rate_limited_until: reset_at,
        rate_limit_remaining: remaining,
        rate_limit_limit: limit,
        rate_limit_reset_at: reset_at,
        rate_limit_observed_at: Time.current
      )

      Rails.logger.warn(
        message: "github_health.rate_limited",
        endpoint: endpoint,
        rate_limited_until: reset_at.iso8601,
        rate_limit_remaining: remaining,
        rate_limit_limit: limit
      )
    end
  end

  # Records the most recently observed GitHub rate-limit quota for this
  # credential endpoint without treating it as an active limit. Called by
  # periodic budget probes (e.g. CheckRateLimitActivity) once per poll
  # cycle so per-installation and per-token usage stays observable on the
  # dashboard between rate-limit events. Best-effort: persistence errors
  # are logged and swallowed so a probe never masks the real API result.
  #
  # A nil +limit+ signals a transport or auth failure (GithubClient#rate_limit_limit
  # returns nil on Octokit::Error). Skipping the update in that case preserves
  # the previously observed quota on the dashboard rather than overwriting it
  # with a misleading zero-remaining / nil-limit reading.
  #
  # @param remaining [Integer, nil] Remaining requests reported by GitHub.
  # @param limit [Integer, nil] Total hourly request limit reported by GitHub.
  # @param reset_at [Time, nil] When the current quota window resets.
  def record_rate_limit_usage!(remaining:, limit:, reset_at: nil)
    return if limit.nil?

    with_lock do
      update!(
        rate_limit_remaining: remaining,
        rate_limit_limit: limit,
        rate_limit_reset_at: reset_at,
        rate_limit_observed_at: Time.current
      )
    end
  rescue => e
    Rails.logger.warn(
      message: "github_health.rate_limit_usage_record_failed",
      endpoint: endpoint,
      error: e.message
    )
  end

  # Percentage (0–100) of the observed quota that has been consumed.
  # Returns nil when no quota has been sampled or the limit is zero/unknown.
  def rate_limit_usage_percent
    return if rate_limit_limit.nil? || rate_limit_limit.zero?
    return if rate_limit_remaining.nil?

    used = rate_limit_limit - rate_limit_remaining
    return 0.0 if used <= 0

    (used.to_f / rate_limit_limit) * 100.0
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

      update!(circuit_state: "half_open", rate_limited_until: nil)

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

  # Returns true if a rate-limit window is currently active.
  def rate_limited?
    rate_limited_until.present? && rate_limited_until > Time.current
  end

  # Returns true when dispatching should be paused — either the circuit is
  # open from infrastructure failures or a GitHub rate limit is still in
  # effect.
  def unavailable?
    circuit_open? || rate_limited?
  end
end
