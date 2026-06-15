# frozen_string_literal: true

class DispatchCircuitBreaker < ApplicationRecord
  CIRCUIT_STATES = %w[closed open half_open].freeze
  DEFAULT_FAILURE_RATE_THRESHOLD = 0.8
  DEFAULT_WINDOW_MINUTES = 15
  DEFAULT_MIN_RUNS = 10
  DEFAULT_RECOVERY_TIMEOUT_MINUTES = 5
  DEFAULT_PROBE_INTERVAL_MINUTES = 5
  DEFAULT_HALF_OPEN_SUCCESS_THRESHOLD = 2
  DEFAULT_HALF_OPEN_FAILURE_THRESHOLD = 2
  DEFAULT_EVALUATION_INTERVAL_MINUTES = 1

  belongs_to :account

  validates :circuit_state, presence: true, inclusion: { in: CIRCUIT_STATES }
  validates :half_open_success_count,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :half_open_failure_count,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :open_circuits, -> { where(circuit_state: "open") }
  scope :half_open_circuits, -> { where(circuit_state: "half_open") }

  def self.for_account(account)
    find_or_initialize_by(account: account)
  end

  def self.for_account!(account)
    find_or_create_by!(account: account)
  rescue ActiveRecord::RecordNotUnique
    find_by!(account: account)
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

  def halted?
    circuit_open? || (circuit_half_open? && recently_probed?)
  end

  def recently_probed?
    last_probe_at.present? && last_probe_at > probe_interval_seconds.seconds.ago
  end

  def trip!(metadata: {})
    with_lock do
      update!(
        circuit_state: "open",
        circuit_opened_at: Time.current,
        half_open_success_count: 0,
        half_open_failure_count: 0,
        trip_metadata: metadata
      )

      Rails.logger.warn(
        message: "dispatch_circuit_breaker.circuit_opened",
        account_id: account_id,
        metadata: metadata
      )
    end
  end

  def record_half_open_failure!
    with_lock do
      new_count = half_open_failure_count + 1
      if new_count >= half_open_failure_threshold
        update!(
          circuit_state: "open",
          circuit_opened_at: Time.current,
          half_open_success_count: 0,
          half_open_failure_count: 0
        )

        Rails.logger.warn(
          message: "dispatch_circuit_breaker.circuit_reopened",
          account_id: account_id,
          half_open_failures: new_count
        )
      else
        update!(half_open_failure_count: new_count, half_open_success_count: 0)
      end
    end
  end

  def record_half_open_success!
    with_lock do
      new_count = half_open_success_count + 1
      if new_count >= half_open_success_threshold
        close!
      else
        update!(half_open_success_count: new_count, half_open_failure_count: 0)
      end
    end
  end

  def check_recovery!
    with_lock do
      return false unless circuit_open?
      return false unless circuit_opened_at.present?
      return false unless circuit_opened_at + recovery_timeout_seconds.seconds <= Time.current

      update!(
        circuit_state: "half_open",
        half_open_success_count: 0,
        half_open_failure_count: 0
      )

      Rails.logger.info(
        message: "dispatch_circuit_breaker.circuit_half_open",
        account_id: account_id
      )
      true
    end
  end

  def close!
    with_lock do
      update!(
        circuit_state: "closed",
        circuit_opened_at: nil,
        last_probe_at: nil,
        half_open_success_count: 0,
        half_open_failure_count: 0,
        trip_metadata: {}
      )

      Rails.logger.info(
        message: "dispatch_circuit_breaker.circuit_closed",
        account_id: account_id
      )
    end
  end

  def evaluation_due?
    last_evaluated_at.nil? || last_evaluated_at < evaluation_interval_seconds.seconds.ago
  end

  def record_evaluation!
    update_columns(last_evaluated_at: Time.current)
  end

  def mark_probe_dispatched!
    update!(last_probe_at: Time.current)
  end

  def probe_allowed?
    return false unless circuit_half_open?
    last_probe_at.nil? || last_probe_at < probe_interval_seconds.seconds.ago
  end

  private

  def recovery_timeout_seconds
    settings = account.tenant_setting
    minutes = settings&.effective_agent_settings&.dig("dispatch_circuit_breaker_recovery_timeout_minutes") ||
      DEFAULT_RECOVERY_TIMEOUT_MINUTES
    minutes.to_i * 60
  end

  def probe_interval_seconds
    settings = account.tenant_setting
    (settings&.effective_agent_settings&.dig("dispatch_circuit_breaker_probe_interval_minutes") ||
      DEFAULT_PROBE_INTERVAL_MINUTES).to_i * 60
  end

  def evaluation_interval_seconds
    settings = account.tenant_setting
    (settings&.effective_agent_settings&.dig("dispatch_circuit_breaker_evaluation_interval_minutes") ||
      DEFAULT_EVALUATION_INTERVAL_MINUTES).to_i * 60
  end

  def half_open_success_threshold
    settings = account.tenant_setting
    (settings&.effective_agent_settings&.dig("dispatch_circuit_breaker_half_open_success_threshold") ||
      DEFAULT_HALF_OPEN_SUCCESS_THRESHOLD).to_i
  end

  def half_open_failure_threshold
    settings = account.tenant_setting
    (settings&.effective_agent_settings&.dig("dispatch_circuit_breaker_half_open_failure_threshold") ||
      DEFAULT_HALF_OPEN_FAILURE_THRESHOLD).to_i
  end
end
