# frozen_string_literal: true

class KnowledgeRun < ApplicationRecord
  LEGACY_PROVIDER_ATTRIBUTE_BRIDGES = {
    "final_provider" => "final_runner",
    "provider_attempts" => "runner_attempts"
  }.freeze

  STATUSES = %w[pending running completed failed].freeze
  ACTIVE_STATUSES = %w[pending running].freeze
  FINISHED_STATUSES = %w[completed failed].freeze
  OPERATION_TYPES = %w[embedding decision_drafting].freeze
  TOKEN_LIMIT_STATUSES = AgentRun::TOKEN_LIMIT_STATUSES
  DEFAULT_MAX_TOKENS_PER_RUN = 10_000

  # @spec KNOWLEDGE-011
  # Structured categories used when persisting a run's failure. Mirrors the
  # `reason:` values callers already compute (see Knowledge::Decisions::Draft
  # and the provider/runner executors) so a future regression is a query
  # against `failure_reason` rather than log archaeology.
  FAILURE_REASONS = %w[
    no_supported_container_providers
    containerized_providers_failed
    in_process_providers_failed
    container_provider_error
    all_providers_exhausted
    no_available_providers
    provider_error
    unparseable_response
    invalid_response
    record_invalid
    container_error
    unhandled_error
  ].freeze

  belongs_to :project
  has_many :token_usages, dependent: :destroy

  before_create :generate_proxy_token

  validates :operation_type, presence: true, inclusion: { in: OPERATION_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :token_limit_status, inclusion: { in: TOKEN_LIMIT_STATUSES }, allow_nil: true
  validates :final_provider, length: { maximum: 50 }
  validates :max_tokens, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :total_tokens, numericality: { greater_than_or_equal_to: 0 }
  validates :failure_reason, inclusion: { in: FAILURE_REASONS }, allow_nil: true
  validates :error_class, length: { maximum: 150 }, allow_nil: true

  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :finished, -> { where(status: FINISHED_STATUSES) }

  LEGACY_PROVIDER_ATTRIBUTE_BRIDGES.each do |legacy_name, runner_name|
    define_method(runner_name) do
      if runner_name == "runner_attempts"
        runner_attempts_from_provider_attempts
      else
        public_send(legacy_name)
      end
    end

    define_method("#{runner_name}=") do |value|
      if runner_name == "runner_attempts"
        self.provider_attempts = provider_attempts_from_runner_attempts(value)
      else
        public_send("#{legacy_name}=", value)
      end
    end
  end

  def active?
    ACTIVE_STATUSES.include?(status)
  end

  def effective_max_tokens_per_run
    max_tokens || DEFAULT_MAX_TOKENS_PER_RUN
  end

  def effective_provider
    attempts = runner_attempts
    final_runner.presence || attempts.last&.fetch("runner", nil) || attempts.last&.fetch("provider", nil) || "unknown"
  end

  alias_method :effective_runner, :effective_provider

  # @spec KNOWLEDGE-011
  # Append a per-attempt entry to `provider_attempts`. Optional outcome kwargs
  # capture why the attempt was recorded the way it was so an empty `attempted_at`
  # row stops being the only signal a failure happened.
  def record_provider_attempt(provider, outcome: nil, error_class: nil, error_message: nil)
    attempt = {
      "provider" => provider,
      "attempted_at" => Time.current.iso8601,
      "outcome" => outcome
    }.compact
    attempt["error_class"] = error_class if error_class
    attempt["error_message"] = error_message if error_message
    update!(provider_attempts: provider_attempts + [ attempt ])
  end

  alias_method :record_runner_attempt, :record_provider_attempt

  # @spec KNOWLEDGE-011
  # Annotate the most-recent attempt for `provider` with an outcome. Callers
  # typically pair this with `record_provider_attempt` so a single attempt
  # entry carries both when it started and how it ended.
  def mark_provider_attempt_outcome(provider:, outcome:, error_class: nil, error_message: nil)
    attempts = Array(provider_attempts).map(&:dup)
    index = attempts.rindex { |attempt| attempt.is_a?(Hash) && attempt["provider"] == provider }
    return if index.nil?

    attempts[index]["outcome"] = outcome
    attempts[index]["error_class"] = error_class if error_class
    attempts[index]["error_message"] = error_message if error_message
    update!(provider_attempts: attempts)
  end

  def mark_runner_attempt_outcome(runner:, outcome:, error_class: nil, error_message: nil)
    mark_provider_attempt_outcome(
      provider: runner,
      outcome: outcome,
      error_class: error_class,
      error_message: error_message
    )
  end

  def ensure_proxy_token!
    return proxy_token if proxy_token.present?

    token = SecureRandom.hex(32)
    updated_rows = self.class.where(id: id, proxy_token: nil).update_all(proxy_token: token)

    if updated_rows == 1
      self.proxy_token = token
    else
      reload
    end

    proxy_token
  end

  def complete!
    return unless active?

    update!(status: "completed", completed_at: Time.current)
  end

  # @spec KNOWLEDGE-011
  # Persist the structured failure context callers already compute so future
  # regressions are a query, not an investigation.
  def fail!(reason: nil, error_class: nil, error_message: nil)
    return unless active?

    attributes = { status: "failed", completed_at: Time.current }
    attributes[:failure_reason] = reason if reason
    attributes[:error_class] = error_class if error_class
    attributes[:error_message] = error_message if error_message
    update!(attributes)
  end

  private

  def runner_attempts_from_provider_attempts
    Array(provider_attempts).map do |attempt|
      next attempt unless attempt.is_a?(Hash)

      provider = attempt["provider"] || attempt["runner"]
      attempt.merge("provider" => provider, "runner" => provider)
    end
  end

  def provider_attempts_from_runner_attempts(value)
    Array(value).map do |attempt|
      next attempt unless attempt.is_a?(Hash)

      attempt.except("runner").merge("provider" => attempt["runner"] || attempt["provider"])
    end
  end

  def generate_proxy_token
    self.proxy_token ||= SecureRandom.hex(32)
  end
end
