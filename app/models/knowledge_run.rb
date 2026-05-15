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

  belongs_to :project
  has_many :token_usages, dependent: :destroy

  before_create :generate_proxy_token

  validates :operation_type, presence: true, inclusion: { in: OPERATION_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :token_limit_status, inclusion: { in: TOKEN_LIMIT_STATUSES }, allow_nil: true
  validates :final_provider, length: { maximum: 50 }
  validates :max_tokens, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :total_tokens, numericality: { greater_than_or_equal_to: 0 }

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
    final_provider.presence || provider_attempts.last&.fetch("provider", nil) || "unknown"
  end

  alias_method :effective_runner, :effective_provider

  def record_provider_attempt(provider)
    attempt = {
      "provider" => provider,
      "attempted_at" => Time.current.iso8601
    }
    update!(provider_attempts: provider_attempts + [ attempt ])
  end

  alias_method :record_runner_attempt, :record_provider_attempt

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
    update!(status: "completed") if active?
  end

  def fail!
    update!(status: "failed") if active?
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
