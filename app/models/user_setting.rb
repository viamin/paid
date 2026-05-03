# frozen_string_literal: true

class UserSetting < ApplicationRecord
  # Max value for PostgreSQL integer columns (32-bit signed)
  PG_INT_MAX = 2_147_483_647
  # Reasonable upper bound for container memory (64 GB in bytes)
  MAX_CONTAINER_MEMORY_BYTES = 64 * 1024 * 1024 * 1024
  # Reasonable upper bound for delay settings (24 hours in seconds)
  MAX_DELAY_SECONDS = 86_400
  KB_EMBEDDING_PROVIDERS = Provider::OPENAI_COMPATIBLE_DIRECT_OUTBOUND_API_PROVIDER_KEYS.freeze
  KB_EMBEDDING_PROVIDER_DEFAULT = "openai"
  KB_CHAT_PROVIDERS = ProviderSupport::APP_PROVIDER_KEYS.freeze
  KB_CHAT_PROVIDER_DEFAULT = "claude"
  PROVIDER_SELECTION_MODES = %w[single round_robin random].freeze
  PROVIDER_SELECTION_MODE_DEFAULT = "single"

  THEME_PREFERENCES = %w[light dark system].freeze

  belongs_to :user
  has_many :provider_states, through: :user

  # Theme
  validates :theme_preference, inclusion: { in: THEME_PREFERENCES }

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
  validate :validate_default_agent_providers_by_goal

  # Container Resources
  validates :container_memory_bytes,
    numericality: { only_integer: true, greater_than_or_equal_to: 512 * 1024 * 1024,
                    less_than_or_equal_to: MAX_CONTAINER_MEMORY_BYTES }
  validates :container_timeout_seconds,
    numericality: { only_integer: true, greater_than_or_equal_to: 60, less_than_or_equal_to: PG_INT_MAX }

  # Concurrency
  validates :max_concurrent_runs,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 100 }
  validates :max_parallel_agents_per_project,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 20 }
  validates :max_auto_pick_open_prs,
    numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validates :fair_queue_across_projects, inclusion: { in: [ true, false ] }

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
  validates :create_pr_idle_timeout_seconds,
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

  # Display Limits
  validates :max_issues_per_page, :max_prs_per_page,
    numericality: { only_integer: true, greater_than_or_equal_to: 5, less_than_or_equal_to: 200 }

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
  validates :provider_selection_mode, inclusion: { in: PROVIDER_SELECTION_MODES }
  validate :validate_fallback_providers
  validate :validate_kb_embedding_provider
  validate :validate_kb_embedding_fallback_providers
  validate :validate_kb_chat_provider
  validate :validate_kb_chat_fallback_providers

  def self.normalize_provider_array_param(value)
    return value unless value.is_a?(String)

    parsed = JSON.parse(value)
    return [] unless parsed.is_a?(Array)

    parsed.select { |provider| provider.is_a?(String) }
  rescue JSON::ParserError
    []
  end

  def self.parse_provider_array_param(value)
    return value unless value.is_a?(String)

    parsed = JSON.parse(value)
    return value unless parsed.is_a?(Array)

    parsed.select { |provider| provider.is_a?(String) }
  rescue JSON::ParserError
    value
  end

  def self.normalize_fallback_providers_param(value)
    normalize_provider_array_param(value)
  end

  # Returns providers enabled for agent runs for a user.
  # Filtered to container-executable providers only, since non-executable
  # providers would cause immediate "All providers exhausted" failures
  # in RunAgentActivity.
  def self.enabled_agent_providers(user = nil, identifiers: false)
    executable_keys = ProviderSupport.container_executable_provider_keys
    return [ "claude" ] & executable_keys unless user
    return executable_keys if user.new_record?

    provider_identifiers_for(
      user.providers.for_agent_runs.where(provider_key: executable_keys).ordered,
      identifiers: identifiers
    )
  end

  # Returns providers that can be used as fallback for a user.
  # Filtered to container-executable providers only, since non-executable
  # providers would cause immediate failures during fallback in RunAgentActivity.
  def self.fallback_candidate_providers(user, identifiers: false)
    executable_keys = ProviderSupport.container_executable_provider_keys
    return [ "claude" ] & executable_keys unless user
    return executable_keys if user.new_record?

    provider_identifiers_for(
      user.providers.for_fallback.where(provider_key: executable_keys).ordered,
      identifiers: identifiers
    )
  end

  # Returns canonical provider keys that have API-key-based entries configured
  # as rate-limit fallbacks. These are only used when the subscription entry
  # for the same provider_key is rate-limited.
  def self.rate_limit_fallback_providers(user)
    return [] unless user
    return [] if user.new_record?

    executable_keys = ProviderSupport.container_executable_provider_keys
    user.providers.api_key.rate_limit_fallback.for_agent_runs.for_fallback
      .where(provider_key: executable_keys)
      .distinct
      .pluck(:provider_key)
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
  def provider_priority(identifiers: false)
    default_identifier = default_provider_identifier
    default = default_identifier.present? ? [ default_identifier ] : []
    priorities = default + fallback_priority_for(primary_provider: default_identifier || default_agent_provider, identifiers: true)

    return priorities if identifiers

    map_identifiers_to_provider_keys(priorities)
  end

  def default_provider_identifier
    normalized_default_agent_provider || allowed_provider_identifiers_for_agent_runs.first
  end

  def default_provider_identifier_for_goal(goal)
    goal = goal.to_s
    goal_provider = default_agent_providers_by_goal[goal] if goal.present?
    return default_provider_identifier if goal_provider.blank?

    resolved = identifiers_for_provider_token(goal_provider, candidates: allowed_provider_identifiers_for_agent_runs).first
    resolved || default_provider_identifier
  end

  # Returns the next automated provider identifier to use for an agent run,
  # honoring the configured provider_selection_mode (single, round_robin,
  # random) and per-provider weights.
  #
  # When fewer than two providers are enabled or the mode is "single",
  # falls back to the goal-specific default provider identifier.
  #
  # round_robin mode persists state on the user_setting so the next call
  # picks up where the previous call left off, respecting provider weights
  # (a provider with weight N is used N consecutive times).
  #
  # @param goal [String, nil] The agent run goal (e.g. "create_pr").
  # @return [String, nil] A provider routing-key identifier or nil if none.
  def select_automated_provider_identifier(goal: nil)
    fallback_identifier = default_provider_identifier_for_goal(goal)
    candidates = allowed_provider_identifiers_for_agent_runs
    return fallback_identifier if candidates.length < 2 || provider_selection_mode == "single"

    case provider_selection_mode
    when "random"
      pick_random_provider_identifier(candidates) || fallback_identifier
    when "round_robin"
      pick_round_robin_provider_identifier(candidates) || fallback_identifier
    else
      fallback_identifier
    end
  end

  def provider_priority_for_goal(goal, identifiers: false)
    goal_identifier = default_provider_identifier_for_goal(goal)
    default = goal_identifier.present? ? [ goal_identifier ] : []
    priorities = default + fallback_priority_for(
      primary_provider: goal_identifier || default_agent_provider,
      identifiers: true
    )

    return priorities if identifiers

    map_identifiers_to_provider_keys(priorities)
  end

  def sanitize_provider_tokens(tokens, candidates:)
    Array(tokens).flat_map do |token|
      token = token.to_s
      next [] if token.blank?
      next token if candidates.include?(token)
      resolved = identifiers_for_provider_token(token, candidates: candidates)
      next resolved if resolved.any?

      []
    end.uniq
  end

  # Returns the ordered fallback providers for the given primary provider.
  # Saved order is respected first, then any other configured fallback providers
  # are appended so newly added providers participate automatically.
  #
  # If the current primary appears in the saved fallback order, fallback wraps
  # around that position so a goal-specific or manually selected primary lower
  # in the list still exhausts the providers after it before wrapping to the
  # providers above it.
  #
  # @param primary_provider [String] The provider already being attempted
  # @return [Array<String>] Fallback provider keys in attempt order
  def fallback_priority_for(primary_provider:, identifiers: false)
    candidates = allowed_provider_identifiers_for_fallback
    saved_order = Array(fallback_providers).flat_map do |provider|
      identifiers_for_provider_token(provider, candidates: candidates)
    end
    ordered_candidates = (saved_order + (candidates - saved_order)).uniq
    primary_identifiers = identifiers_for_provider_token(primary_provider, candidates: ordered_candidates)
    primary_index = saved_order.index { |provider| primary_identifiers.include?(provider) || provider == primary_provider }
    rotated_candidates = primary_index ? ordered_candidates.rotate(primary_index + 1) : ordered_candidates
    priorities = rotated_candidates.reject { |provider| primary_identifiers.include?(provider) || provider == primary_provider }
    return priorities if identifiers

    map_identifiers_to_provider_keys(priorities)
  end

  # Returns providers that are currently available (not rate limited, circuit not open).
  # Checks ProviderState for each provider and filters out unavailable ones.
  #
  # @param check_circuit_recovery [Boolean] Whether to check for circuit recovery before filtering
  # @return [Array<String>] Available provider names in priority order
  def available_providers(check_circuit_recovery: true, identifiers: false)
    priorities = provider_priority(identifiers: true)
    provider_keys_by_identifier = priorities.index_with do |identifier|
      provider_key_for_identifier(identifier)
    end
    provider_keys = provider_keys_by_identifier.values.uniq
    states_by_name = user.provider_states.where(provider_name: priorities + provider_keys).index_by(&:provider_name)

    available = priorities.select do |provider|
      state = states_by_name[provider] || states_by_name[provider_keys_by_identifier[provider]]
      next true unless state

      # Check if circuit can recover before filtering
      state.check_circuit_recovery!(timeout: circuit_breaker_timeout_seconds) if check_circuit_recovery

      !state.unavailable?
    end

    return available if identifiers

    map_identifiers_to_provider_keys(available)
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

  # Picks a candidate at random, weighted by each provider's weight column.
  # Falls back to uniform random when weights cannot be resolved (e.g. no
  # user attached for unsaved settings).
  def pick_random_provider_identifier(candidates)
    weighted = weighted_candidate_pairs(candidates)
    return candidates.sample if weighted.empty?

    total = weighted.sum { |(_id, weight)| weight }
    return weighted.first.first if total <= 0

    target = SecureRandom.random_number(total)
    cumulative = 0
    weighted.each do |identifier, weight|
      cumulative += weight
      return identifier if target < cumulative
    end
    weighted.last.first
  end

  # Picks the next provider in round-robin order, repeating each provider
  # consecutively N times when its weight is N. Persists state on the
  # user_setting so subsequent calls advance the cursor.
  def pick_round_robin_provider_identifier(candidates)
    weighted = weighted_candidate_pairs(candidates)
    return candidates.first if weighted.empty?

    state = round_robin_state_for(weighted)
    cursor = (state["index"] || 0) % weighted.length
    identifier, weight = weighted[cursor]
    consumed = (state["consumed"] || 0) + 1

    if consumed >= weight
      state["index"] = (cursor + 1) % weighted.length
      state["consumed"] = 0
    else
      state["index"] = cursor
      state["consumed"] = consumed
    end
    state["fingerprint"] = round_robin_fingerprint(weighted)

    persist_round_robin_state!(state)
    identifier
  end

  # Returns [[identifier, weight], ...] in candidate order, looking up each
  # provider's weight from the user's saved providers. Unknown identifiers
  # fall back to Provider::DEFAULT_WEIGHT so the cycle still advances.
  def weighted_candidate_pairs(candidates)
    weights_by_identifier = provider_weights_by_identifier(candidates)
    candidates.map do |identifier|
      [ identifier, weights_by_identifier.fetch(identifier, Provider::DEFAULT_WEIGHT) ]
    end
  end

  def provider_weights_by_identifier(candidates)
    return {} unless user
    return {} if user.new_record?

    routing_ids = candidates.filter_map { |identifier| Provider.id_from_routing_key(identifier) }
    return {} if routing_ids.empty?

    user.providers.where(id: routing_ids).pluck(:id, :weight).to_h do |id, weight|
      [ "#{Provider::ROUTING_KEY_PREFIX}#{id}", weight || Provider::DEFAULT_WEIGHT ]
    end
  end

  # Returns a fingerprint for the current candidate ordering and weights so
  # the cursor resets when providers are added, removed, or re-weighted.
  def round_robin_fingerprint(weighted)
    weighted.map { |identifier, weight| "#{identifier}:#{weight}" }.join("|")
  end

  def round_robin_state_for(weighted)
    state = provider_round_robin_state.is_a?(Hash) ? provider_round_robin_state.dup : {}
    fingerprint = round_robin_fingerprint(weighted)
    state = {} if state["fingerprint"] != fingerprint
    state
  end

  def persist_round_robin_state!(state)
    return unless persisted?

    update_column(:provider_round_robin_state, state)
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.warn(
      message: "user_setting.round_robin_state_persist_failed",
      user_id: user_id,
      error: e.message
    )
  end

  def validate_fallback_providers
    return if fallback_providers.blank?

    unless fallback_providers.is_a?(Array)
      errors.add(:fallback_providers, "must be an array")
      return
    end

    self.fallback_providers = sanitize_provider_tokens(fallback_providers, candidates: allowed_provider_identifiers_for_fallback)
  end

  def validate_kb_embedding_provider
    self.kb_embedding_provider = normalize_kb_provider(kb_embedding_provider, default: KB_EMBEDDING_PROVIDER_DEFAULT)
    return if KB_EMBEDDING_PROVIDERS.include?(kb_embedding_provider)

    errors.add(:kb_embedding_provider, "is not a supported knowledge embedding provider")
  end

  def validate_kb_embedding_fallback_providers
    self.kb_embedding_fallback_providers = normalize_kb_provider_list(
      kb_embedding_fallback_providers,
      attribute: :kb_embedding_fallback_providers,
      supported_providers: KB_EMBEDDING_PROVIDERS
    )
  end

  def validate_kb_chat_provider
    self.kb_chat_provider = normalize_kb_provider(kb_chat_provider, default: KB_CHAT_PROVIDER_DEFAULT)
    return if KB_CHAT_PROVIDERS.include?(kb_chat_provider)

    errors.add(:kb_chat_provider, "is not a supported knowledge chat provider")
  end

  def validate_kb_chat_fallback_providers
    self.kb_chat_fallback_providers = normalize_kb_provider_list(
      kb_chat_fallback_providers,
      attribute: :kb_chat_fallback_providers,
      supported_providers: KB_CHAT_PROVIDERS
    )
  end

  def validate_default_agent_providers_by_goal
    return if default_agent_providers_by_goal.blank?

    unless default_agent_providers_by_goal.is_a?(Hash)
      errors.add(:default_agent_providers_by_goal, "must be a hash")
      return
    end

    allowed_goals = AgentRun::GOALS
    allowed_providers = allowed_provider_identifiers_for_agent_runs
    normalized = {}

    default_agent_providers_by_goal.each do |goal, provider|
      goal = goal.to_s

      unless allowed_goals.include?(goal)
        errors.add(:default_agent_providers_by_goal, "contains invalid goal: #{goal}")
        next
      end

      next if provider.blank?

      resolved = identifiers_for_provider_token(provider.to_s, candidates: allowed_providers)
      if resolved.empty? && !allowed_providers.include?(provider.to_s)
        errors.add(:default_agent_providers_by_goal, "contains invalid provider for #{goal}")
        next
      end

      normalized[goal] = resolved.first || provider.to_s
    end

    self.default_agent_providers_by_goal = normalized
  end

  def validate_default_agent_provider
    allowed = allowed_provider_identifiers_for_agent_runs
    token = default_agent_provider.to_s
    normalized = normalized_default_agent_provider

    if token.present? && allowed.include?(token)
      self.default_agent_provider = token
      return
    end

    if normalized.present?
      self.default_agent_provider = normalized
      return
    end

    if allowed.any?
      self.default_agent_provider = allowed.first
      return
    end

    errors.add(:default_agent_provider, "is not an enabled provider")
  end

  def allowed_provider_identifiers_for_agent_runs
    return self.class.enabled_agent_providers(nil, identifiers: true) unless user
    return self.class.enabled_agent_providers(user, identifiers: true) if user.new_record?

    executable_keys = ProviderSupport.container_executable_provider_keys
    self.class.provider_identifiers_for(
      user.providers.for_agent_runs.where(provider_key: executable_keys).ordered,
      identifiers: true
    )
  end

  def allowed_provider_identifiers_for_fallback
    return self.class.fallback_candidate_providers(nil, identifiers: true) unless user
    return self.class.fallback_candidate_providers(user, identifiers: true) if user.new_record?

    executable_keys = ProviderSupport.container_executable_provider_keys
    self.class.provider_identifiers_for(
      user.providers.for_fallback.where(provider_key: executable_keys).ordered,
      identifiers: true
    )
  end

  def normalized_default_agent_provider
    identifiers_for_provider_token(default_agent_provider, candidates: allowed_provider_identifiers_for_agent_runs).first
  end

  def identifiers_for_provider_token(token, candidates:)
    token = token.to_s
    return [] if token.blank?

    exact = candidates.select { |candidate| candidate == token }
    return exact if exact.any?
    return [] unless user

    provider_index_by_id = {}
    routing_ids = candidates.filter_map.with_index do |candidate, index|
      provider_id = Provider.id_from_routing_key(candidate)
      provider_index_by_id[provider_id] ||= index if provider_id
      provider_id
    end
    return [] if routing_ids.empty?

    matching_providers = user.providers.where(id: routing_ids, provider_key: token).ordered.to_a
    return [] if matching_providers.empty?

    preferred_provider = matching_providers.min_by do |provider|
      [
        provider.subscription? ? 0 : 1,
        provider_index_by_id.fetch(provider.id, Float::INFINITY)
      ]
    end
    preferred_identifier = "#{Provider::ROUTING_KEY_PREFIX}#{preferred_provider.id}"

    candidates.include?(preferred_identifier) ? [ preferred_identifier ] : []
  end

  def map_identifiers_to_provider_keys(identifiers)
    Array(identifiers).map do |identifier|
      provider_key_for_identifier(identifier)
    end.uniq
  end

  def provider_key_for_identifier(identifier)
    Provider.for_identifier(user, identifier)&.provider_key || identifier
  end

  def normalize_kb_provider(value, default:)
    value.to_s.strip.downcase.presence || default
  end

  def normalize_kb_provider_list(value, attribute:, supported_providers: nil)
    return [] if value.nil?

    unless value.is_a?(Array)
      errors.add(attribute, "must be an array")
      return value
    end

    normalized = value.filter_map do |provider|
      provider.to_s.strip.downcase.presence
    end.uniq

    return normalized unless supported_providers

    unsupported = normalized - supported_providers
    if unsupported.any?
      errors.add(attribute, "contains unsupported providers: #{unsupported.join(', ')}")
    end

    normalized
  end

  def self.provider_identifiers_for(providers, identifiers:)
    if identifiers
      providers.pluck(:id).map { |id| "#{Provider::ROUTING_KEY_PREFIX}#{id}" }
    else
      providers.pluck(:provider_key).uniq
    end
  end
end
