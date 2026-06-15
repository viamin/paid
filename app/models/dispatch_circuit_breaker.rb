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
  belongs_to :last_probe_run, class_name: "AgentRun", optional: true

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
        last_probe_run_id: nil,
        trip_metadata: metadata
      )

      Rails.logger.warn(
        message: "dispatch_circuit_breaker.circuit_opened",
        account_id: account_id,
        metadata: metadata
      )
    end
  end

  # Records a half_open failure. The agent_run_id is the AgentRun that just
  # completed; the breaker only counts it as a probe signal if it matches
  # the run the dispatcher explicitly marked as the probe via
  # mark_probe_dispatched!. Stale in-flight runs from before the circuit
  # opened can complete during the half_open window — those must not
  # increment half_open_failure_count or they can re-open the breaker
  # without testing a fresh dispatch.
  def record_half_open_failure!(agent_run_id:)
    with_lock do
      return :stale unless circuit_half_open? && last_probe_run_id == agent_run_id

      new_count = half_open_failure_count + 1
      if new_count >= half_open_failure_threshold
        update!(
          circuit_state: "open",
          circuit_opened_at: Time.current,
          half_open_success_count: 0,
          half_open_failure_count: 0,
          last_probe_run_id: nil
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

  # Records a half_open success. See #record_half_open_failure! for why the
  # agent_run_id argument is required: a stale in-flight run completing
  # successfully during half_open must not close the breaker.
  def record_half_open_success!(agent_run_id:)
    with_lock do
      return :stale unless circuit_half_open? && last_probe_run_id == agent_run_id

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
        half_open_failure_count: 0,
        last_probe_run_id: nil
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
        last_probe_run_id: nil,
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

  # Atomically checks the evaluation interval and stamps last_evaluated_at
  # under the row lock. Returns true if this caller won the right to run
  # the (relatively expensive) provider-failure scan; false if another
  # concurrent completion already claimed the slot. This prevents a burst
  # of terminal-run completions during a tightly-clustered provider outage
  # from each issuing its own evaluation query.
  def claim_evaluation!
    with_lock do
      return false unless evaluation_due?

      update!(last_evaluated_at: Time.current)
      true
    end
  end

  # Stamps the probe run id and timestamp. The id is what gates
  # record_half_open_success!/record_half_open_failure!, so the dispatcher
  # must pass the AgentRun it is about to start as the probe. A second call
  # for the same id is a no-op timestamp-wise; for a different id the
  # previous probe is considered abandoned (its outcome, if it ever lands,
  # will be ignored) and the new run becomes the tracked probe.
  def mark_probe_dispatched!(agent_run_id:)
    update!(last_probe_at: Time.current, last_probe_run_id: agent_run_id)
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
