# frozen_string_literal: true

class UserSetting < ApplicationRecord
  # All known providers. Validation uses this full list so that a saved default
  # is not rejected when a provider is temporarily disabled via environment flags.
  AGENT_PROVIDERS = %w[claude cursor aider].freeze

  # Max value for PostgreSQL integer columns (32-bit signed)
  PG_INT_MAX = 2_147_483_647
  # Reasonable upper bound for container memory (64 GB in bytes)
  MAX_CONTAINER_MEMORY_BYTES = 64 * 1024 * 1024 * 1024
  # Reasonable upper bound for delay settings (24 hours in seconds)
  MAX_DELAY_SECONDS = 86_400

  belongs_to :user
  has_many :provider_states, through: :user

  # Polling & Timing
  validates :default_poll_interval_seconds,
    numericality: { only_integer: true, greater_than_or_equal_to: 60, less_than_or_equal_to: PG_INT_MAX }
  validates :github_token_cache_ttl_minutes,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: PG_INT_MAX }
  validates :token_validation_stale_minutes,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: PG_INT_MAX }

  # Agent Execution
  validates :agent_timeout_seconds,
    numericality: { only_integer: true, greater_than_or_equal_to: 60, less_than_or_equal_to: PG_INT_MAX }
  validates :default_agent_provider, inclusion: { in: AGENT_PROVIDERS }

  # Container Resources
  validates :container_memory_bytes,
    numericality: { only_integer: true, greater_than_or_equal_to: 512 * 1024 * 1024,
                    less_than_or_equal_to: MAX_CONTAINER_MEMORY_BYTES }
  validates :container_cpu_quota,
    numericality: { only_integer: true, greater_than_or_equal_to: 100_000, less_than_or_equal_to: PG_INT_MAX }
  validates :container_timeout_seconds,
    numericality: { only_integer: true, greater_than_or_equal_to: 60, less_than_or_equal_to: PG_INT_MAX }

  # Project Defaults
  validates :default_branch, presence: true

  # Retry & Resilience
  validates :circuit_breaker_failure_threshold,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: PG_INT_MAX }
  validates :circuit_breaker_timeout_seconds,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: PG_INT_MAX }
  validates :retry_max_attempts,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: PG_INT_MAX }
  validates :retry_base_delay,
    numericality: { greater_than: 0, less_than_or_equal_to: MAX_DELAY_SECONDS }
  validates :retry_max_delay,
    numericality: { greater_than: 0, less_than_or_equal_to: MAX_DELAY_SECONDS }

  # Provider Fallback
  validate :validate_fallback_providers

  # Returns providers currently enabled at the system level. Claude is always
  # enabled; other providers are gated by environment flags (see
  # config/initializers/agent_harness.rb).
  def self.enabled_agent_providers
    providers = [ "claude" ]
    providers << "cursor" if ENV.fetch("CURSOR_ENABLED", "false") == "true"
    providers << "aider" if ENV.fetch("AIDER_ENABLED", "false") == "true"
    providers
  end

  # Returns default_allowed_github_usernames as a comma-separated string
  def default_allowed_github_usernames_csv
    default_allowed_github_usernames.join(", ")
  end

  # Sets default_allowed_github_usernames from a comma-separated string
  def default_allowed_github_usernames_csv=(value)
    self.default_allowed_github_usernames = value.to_s.split(",").map(&:strip).reject(&:blank?).uniq
  end

  # Returns container memory in a human-readable format (GB)
  def container_memory_gb
    container_memory_bytes / (1024.0 * 1024 * 1024)
  end

  # Sets container memory from a human-readable GB value
  def container_memory_gb=(value)
    self.container_memory_bytes = (value.to_f * 1024 * 1024 * 1024).to_i
  end

  # Returns the allowed service images list
  def allowed_service_images_list
    allowed_service_images || []
  end

  # Sets allowed service images from an array
  def allowed_service_images_list=(value)
    self.allowed_service_images = Array(value).reject(&:blank?).uniq
  end

  # Returns container CPU count (cpu_quota / 100_000)
  def container_cpus
    container_cpu_quota / 100_000
  end

  # Sets container CPU quota from a CPU count
  def container_cpus=(value)
    self.container_cpu_quota = (value.to_i * 100_000)
  end

  # Returns the ordered list of providers to try: primary first, then fallbacks.
  #
  # @return [Array<String>] Provider names in priority order
  def provider_priority
    [ default_agent_provider ] + (fallback_providers || []).reject { |p| p == default_agent_provider }
  end

  # Returns providers that are currently available (not rate limited, circuit not open).
  # Checks ProviderState for each provider and filters out unavailable ones.
  #
  # @param check_circuit_recovery [Boolean] Whether to check for circuit recovery before filtering
  # @return [Array<String>] Available provider names in priority order
  def available_providers(check_circuit_recovery: true)
    provider_priority.select do |provider|
      state = user.provider_states.find_by(provider_name: provider)
      next true unless state

      # Check if circuit can recover before filtering
      state.check_circuit_recovery!(timeout: circuit_breaker_timeout_seconds) if check_circuit_recovery

      !state.unavailable?
    end
  end

  # Returns the ProviderState for a given provider, creating one if it doesn't exist.
  #
  # @param provider_name [String] The provider name
  # @return [ProviderState]
  def provider_state_for(provider_name)
    user.provider_states.find_or_create_by!(provider_name: provider_name)
  end

  private

  def validate_fallback_providers
    return if fallback_providers.blank?

    invalid = fallback_providers - AGENT_PROVIDERS
    if invalid.any?
      errors.add(:fallback_providers, "contains invalid providers: #{invalid.join(', ')}")
    end
  end
end
