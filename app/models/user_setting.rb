# frozen_string_literal: true

class UserSetting < ApplicationRecord
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
  validate :validate_default_agent_provider

  # Container Resources
  validates :container_memory_bytes,
    numericality: { only_integer: true, greater_than_or_equal_to: 512 * 1024 * 1024,
                    less_than_or_equal_to: MAX_CONTAINER_MEMORY_BYTES }
  validates :container_timeout_seconds,
    numericality: { only_integer: true, greater_than_or_equal_to: 60, less_than_or_equal_to: PG_INT_MAX }

  # Concurrency
  validates :max_concurrent_runs,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 100 }

  # Token & rate limits
  validates :max_tokens_per_run,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: PG_INT_MAX }

  # Goal-specific timeouts
  validates :issue_goal_timeout_seconds,
    numericality: { only_integer: true, greater_than_or_equal_to: 30, less_than_or_equal_to: PG_INT_MAX }
  validates :issue_goal_idle_timeout_seconds,
    numericality: { only_integer: true, greater_than_or_equal_to: 30, less_than_or_equal_to: PG_INT_MAX }
  validates :review_goal_idle_timeout_seconds,
    numericality: { only_integer: true, greater_than_or_equal_to: 30, less_than_or_equal_to: PG_INT_MAX }

  # Git operation timeouts
  validates :git_clone_timeout_seconds,
    numericality: { only_integer: true, greater_than_or_equal_to: 30, less_than_or_equal_to: PG_INT_MAX }
  validates :git_push_timeout_seconds,
    numericality: { only_integer: true, greater_than_or_equal_to: 10, less_than_or_equal_to: PG_INT_MAX }

  # Prompt building limits
  validates :max_prompt_comments,
    numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: PG_INT_MAX }
  validates :max_comment_length,
    numericality: { only_integer: true, greater_than_or_equal_to: 100, less_than_or_equal_to: PG_INT_MAX }

  # Style guide byte limits
  validates :style_guide_max_raw_bytes,
    numericality: { only_integer: true, greater_than_or_equal_to: 1000, less_than_or_equal_to: PG_INT_MAX }
  validates :style_guide_max_total_bytes,
    numericality: { only_integer: true, greater_than_or_equal_to: 1000, less_than_or_equal_to: PG_INT_MAX }
  validates :style_guide_max_raw_prompt_bytes,
    numericality: { only_integer: true, greater_than_or_equal_to: 1000, less_than_or_equal_to: PG_INT_MAX }

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

  def self.normalize_fallback_providers_param(value)
    return value unless value.is_a?(String)

    parsed = JSON.parse(value)
    return [] unless parsed.is_a?(Array)

    parsed.select { |provider| provider.is_a?(String) }
  rescue JSON::ParserError
    []
  end

  # Returns providers enabled for agent runs for a user.
  # Filtered to container-executable providers only, since non-executable
  # providers would cause immediate "All providers exhausted" failures
  # in RunAgentActivity.
  def self.enabled_agent_providers(user = nil)
    executable_keys = ProviderSupport.container_executable_provider_keys
    return [ "claude" ] & executable_keys unless user
    return executable_keys if user.new_record?

    user.providers.for_agent_runs.ordered.pluck(:provider_key).uniq & executable_keys
  end

  # Returns providers that can be used as fallback for a user.
  # Filtered to container-executable providers only, since non-executable
  # providers would cause immediate failures during fallback in RunAgentActivity.
  def self.fallback_candidate_providers(user)
    executable_keys = ProviderSupport.container_executable_provider_keys
    return [ "claude" ] & executable_keys unless user
    return executable_keys if user.new_record?

    user.providers.for_fallback.ordered.pluck(:provider_key).uniq & executable_keys
  end

  # Returns provider keys that have API-key-based entries configured as
  # rate-limit fallbacks. These are only used when the subscription entry
  # for the same provider_key is rate-limited.
  def self.rate_limit_fallback_providers(user)
    return [] unless user
    return [] if user.new_record?

    executable_keys = ProviderSupport.container_executable_provider_keys
    user.providers.api_key.rate_limit_fallback.for_agent_runs.for_fallback
      .pluck(:provider_key).uniq & executable_keys
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

  # Returns allowed_service_images as a comma-separated string
  def allowed_service_images_csv
    (allowed_service_images || []).join(", ")
  end

  # Sets allowed_service_images from a comma-separated string
  def allowed_service_images_csv=(value)
    self.allowed_service_images = value.to_s.split(",").map(&:strip).reject(&:blank?).uniq
  end

  # Returns the ordered list of providers to try: primary first, then fallbacks.
  #
  # @return [Array<String>] Provider names in priority order
  def provider_priority
    default = allowed_provider_keys_for_agent_runs.include?(default_agent_provider) ? [ default_agent_provider ] : []
    default + fallback_priority_for(primary_provider: default_agent_provider)
  end

  # Returns the ordered fallback providers for the given primary provider.
  # Saved order is respected first, then any other configured fallback providers
  # are appended so newly added providers participate automatically.
  #
  # @param primary_provider [String] The provider already being attempted
  # @return [Array<String>] Fallback provider keys in attempt order
  def fallback_priority_for(primary_provider:)
    candidates = allowed_provider_keys_for_fallback.reject { |provider| provider == primary_provider }
    saved_order = Array(fallback_providers)
      .reject { |provider| provider == primary_provider }
      .select { |provider| candidates.include?(provider) }

    (saved_order + (candidates - saved_order)).uniq
  end

  # Returns providers that are currently available (not rate limited, circuit not open).
  # Checks ProviderState for each provider and filters out unavailable ones.
  #
  # @param check_circuit_recovery [Boolean] Whether to check for circuit recovery before filtering
  # @return [Array<String>] Available provider names in priority order
  def available_providers(check_circuit_recovery: true)
    priorities = provider_priority
    states_by_name = user.provider_states.where(provider_name: priorities).index_by(&:provider_name)

    priorities.select do |provider|
      state = states_by_name[provider]
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
  rescue ActiveRecord::RecordNotUnique
    user.provider_states.find_by!(provider_name: provider_name)
  end

  private

  def validate_fallback_providers
    return if fallback_providers.blank?

    unless fallback_providers.is_a?(Array)
      errors.add(:fallback_providers, "must be an array")
      return
    end

    self.fallback_providers = fallback_providers & allowed_provider_keys_for_fallback
  end

  def validate_default_agent_provider
    allowed = allowed_provider_keys_for_agent_runs
    return if allowed.include?(default_agent_provider)

    if allowed.any?
      self.default_agent_provider = allowed.first
      return
    end

    errors.add(:default_agent_provider, "is not an enabled provider")
  end

  def allowed_provider_keys_for_agent_runs
    self.class.enabled_agent_providers(user)
  end

  def allowed_provider_keys_for_fallback
    self.class.fallback_candidate_providers(user)
  end
end
