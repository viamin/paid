# frozen_string_literal: true

class UserSetting < ApplicationRecord
  include AutoPickSkipLabels
  has_logidze
  LEGACY_PROVIDER_ATTRIBUTE_BRIDGES = {
    "default_agent_provider" => "default_agent_runner",
    "default_agent_providers_by_goal" => "default_agent_runners_by_goal",
    "fallback_providers" => "fallback_runners",
    "provider_selection_mode" => "runner_selection_mode",
    "provider_round_robin_state" => "runner_round_robin_state",
    "kb_chat_provider" => "kb_chat_runner",
    "kb_chat_fallback_providers" => "kb_chat_fallback_runners",
    "kb_embedding_provider" => "kb_embedding_runner",
    "kb_embedding_fallback_providers" => "kb_embedding_fallback_runners"
  }.freeze
  # Max value for PostgreSQL integer columns (32-bit signed)
  PG_INT_MAX = 2_147_483_647
  # Reasonable upper bound for container memory (64 GB in bytes)
  MAX_CONTAINER_MEMORY_BYTES = 64 * 1024 * 1024 * 1024
  # Reasonable upper bound for delay settings (24 hours in seconds)
  MAX_DELAY_SECONDS = 86_400
  KB_EMBEDDING_RUNNERS = Runner::OPENAI_COMPATIBLE_DIRECT_OUTBOUND_API_PROVIDER_KEYS.freeze
  KB_EMBEDDING_RUNNER_DEFAULT = "openai"
  KB_CHAT_RUNNERS = RunnerSupport::APP_RUNNER_KEYS.freeze
  KB_CHAT_RUNNER_DEFAULT = "claude"
  RUNNER_SELECTION_MODES = %w[single round_robin random].freeze
  RUNNER_SELECTION_MODE_DEFAULT = "single"
  AGENT_UPDATE_COMMENT_MODES = %w[off summary].freeze
  AGENT_UPDATE_COMMENT_MODE_DEFAULT = "off"
  RUN_CONCURRENCY_MODES = %w[manual auto].freeze
  RUN_CONCURRENCY_MODE_MANUAL = "manual"
  RUN_CONCURRENCY_MODE_AUTO = "auto"

  THEME_PREFERENCES = %w[light dark system].freeze

  belongs_to :user
  has_many :runner_states, through: :user

  def update_columns(attributes)
    normalized = attributes.to_h.stringify_keys

    LEGACY_PROVIDER_ATTRIBUTE_BRIDGES.each do |legacy_name, runner_name|
      next unless normalized.key?(legacy_name)
      next if normalized.key?(runner_name)

      normalized[runner_name] = normalized.delete(legacy_name)
    end

    super(normalized)
  end

  # Theme
  validates :theme_preference, inclusion: { in: THEME_PREFERENCES }

  def default_agent_provider = runner_key_for_identifier(default_agent_runner)

  def default_agent_provider=(value)
    self.default_agent_runner = value
  end

  def default_agent_providers_by_goal = default_agent_runners_by_goal

  def default_agent_providers_by_goal=(value)
    self.default_agent_runners_by_goal = value
  end

  def fallback_providers = map_identifiers_to_runner_keys(fallback_runners)

  def fallback_providers=(value)
    self.fallback_runners = value
  end

  def provider_selection_mode = runner_selection_mode

  def provider_selection_mode=(value)
    self.runner_selection_mode = value
  end

  def provider_round_robin_state = runner_round_robin_state

  def provider_round_robin_state=(value)
    self.runner_round_robin_state = value
  end

  def kb_chat_provider = runner_key_for_identifier(kb_chat_runner)

  def kb_chat_provider=(value)
    self.kb_chat_runner = value
  end

  def kb_chat_fallback_providers = map_identifiers_to_runner_keys(kb_chat_fallback_runners)

  def kb_chat_fallback_providers=(value)
    self.kb_chat_fallback_runners = value
  end

  def kb_embedding_provider = runner_key_for_identifier(kb_embedding_runner)

  def kb_embedding_provider=(value)
    self.kb_embedding_runner = value
  end

  def kb_embedding_fallback_providers = map_identifiers_to_runner_keys(kb_embedding_fallback_runners)

  def kb_embedding_fallback_providers=(value)
    self.kb_embedding_fallback_runners = value
  end

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
  validate :validate_default_agent_runner
  validate :validate_default_agent_runners_by_goal

  # Container Resources
  validates :container_memory_bytes,
    numericality: { only_integer: true, greater_than_or_equal_to: 512 * 1024 * 1024,
                    less_than_or_equal_to: MAX_CONTAINER_MEMORY_BYTES }
  validates :container_timeout_seconds,
    numericality: { only_integer: true, greater_than_or_equal_to: 60, less_than_or_equal_to: PG_INT_MAX }

  # Concurrency
  validates :run_concurrency_mode, inclusion: { in: RUN_CONCURRENCY_MODES }
  validates :max_concurrent_runs,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 100 },
    allow_nil: true
  validates :max_parallel_agents_per_project,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 20 }
  # Deprecated: retained only for migration safety. Auto-pick no longer
  # uses this setting; max_concurrent_runs is the capacity control.
  validates :max_auto_pick_open_prs,
    numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }

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
    numericality: { only_integer: true, greater_than_or_equal_to: 30, less_than_or_equal_to: PG_INT_MAX },
    allow_nil: true

  # Max execution time override (nil defers to project setting)
  validates :max_execution_seconds,
    numericality: { only_integer: true, greater_than_or_equal_to: 60, less_than_or_equal_to: 86_400 },
    allow_nil: true

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
  validates :agent_update_comment_mode, inclusion: { in: AGENT_UPDATE_COMMENT_MODES }

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

  # Runner Fallback
  validates :runner_selection_mode, inclusion: { in: RUNNER_SELECTION_MODES }
  validate :validate_fallback_runners
  validate :validate_kb_embedding_runner
  validate :validate_kb_embedding_fallback_runners
  validate :validate_kb_chat_runner
  validate :validate_kb_chat_fallback_runners
  validate :validate_max_concurrent_runs_for_mode

  def self.normalize_runner_array_param(value)
    return value unless value.is_a?(String)

    parsed = JSON.parse(value)
    return [] unless parsed.is_a?(Array)

    parsed.select { |runner| runner.is_a?(String) }
  rescue JSON::ParserError
    []
  end

  def run_concurrency_auto?
    run_concurrency_mode == RUN_CONCURRENCY_MODE_AUTO
  end

  def run_concurrency_manual?
    run_concurrency_mode == RUN_CONCURRENCY_MODE_MANUAL
  end

  def self.parse_runner_array_param(value)
    return value unless value.is_a?(String)

    parsed = JSON.parse(value)
    return value unless parsed.is_a?(Array)

    parsed.select { |runner| runner.is_a?(String) }
  rescue JSON::ParserError
    value
  end

  def self.normalize_fallback_runners_param(value)
    normalize_runner_array_param(value)
  end

  # Returns runners enabled for agent runs for a user.
  # Filtered to container-executable runners only, since non-executable
  # runners would cause immediate "All runners exhausted" failures
  # in RunAgentActivity.
  def self.enabled_agent_runners(user = nil, identifiers: false)
    executable_keys = RunnerSupport.container_executable_runner_keys
    return [ "claude" ] & executable_keys unless user
    return executable_keys if user.new_record?

    runner_identifiers_for(
      user.runners.kept_only.for_agent_runs.where(runner_key: executable_keys).ordered,
      identifiers: identifiers
    )
  end

  def self.enabled_agent_providers(user = nil, identifiers: false)
    enabled_agent_runners(user, identifiers: identifiers)
  end

  # Returns runners that can be used as fallback for a user.
  # Filtered to container-executable runners only, since non-executable
  # runners would cause immediate failures during fallback in RunAgentActivity.
  def self.fallback_candidate_runners(user, identifiers: false)
    executable_keys = RunnerSupport.container_executable_runner_keys
    return [ "claude" ] & executable_keys unless user
    return executable_keys if user.new_record?

    runner_identifiers_for(
      user.runners.kept_only.for_fallback.where(runner_key: executable_keys).ordered,
      identifiers: identifiers
    )
  end

  class << self
    alias_method :fallback_candidate_providers, :fallback_candidate_runners
  end

  # Returns canonical runner keys that have API-key-based entries configured
  # as rate-limit fallbacks. These are only used when the subscription entry
  # for the same runner_key is rate-limited.
  def self.rate_limit_fallback_runners(user)
    return [] unless user
    return [] if user.new_record?

    executable_keys = RunnerSupport.container_executable_runner_keys
    user.runners.kept_only.api_key.rate_limit_fallback.for_agent_runs.for_fallback
      .where(runner_key: executable_keys)
      .distinct
      .pluck(:runner_key)
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

  # Returns the ordered list of runners to try: primary first, then fallbacks.
  #
  # @return [Array<String>] Runner names in priority order
  def runner_priority(identifiers: false)
    default_identifier = default_runner_identifier
    default = default_identifier.present? ? [ default_identifier ] : []
    priorities = default + fallback_priority_for(primary_runner: default_identifier || default_agent_runner, identifiers: true)

    return priorities if identifiers

    map_identifiers_to_runner_keys(priorities)
  end

  alias_method :provider_priority, :runner_priority

  def default_runner_identifier
    normalized_default_agent_runner || allowed_runner_identifiers_for_agent_runs.first
  end

  alias_method :default_provider_identifier, :default_runner_identifier

  def default_runner_identifier_for_goal(goal)
    goal = goal.to_s
    goal_runner = default_agent_runners_by_goal[goal] if goal.present?
    return default_runner_identifier if goal_runner.blank?

    resolved = identifiers_for_runner_token(goal_runner, candidates: allowed_runner_identifiers_for_agent_runs).first
    resolved || default_runner_identifier
  end

  alias_method :default_provider_identifier_for_goal, :default_runner_identifier_for_goal

  # Returns the next automated runner identifier to use for an agent run,
  # honoring the configured runner_selection_mode (single, round_robin,
  # random) and per-runner weights.
  #
  # When fewer than two runners are enabled or the mode is "single",
  # falls back to the goal-specific default runner identifier.
  #
  # round_robin mode persists state on the user_setting so the next call
  # picks up where the previous call left off, respecting runner weights
  # (a runner with weight N is used N consecutive times).
  #
  # @param goal [String, nil] The agent run goal (e.g. "create_pr").
  # @return [String, nil] A runner routing-key identifier or nil if none.
  def select_automated_runner_identifier(goal: nil)
    fallback_identifier = default_runner_identifier_for_goal(goal)
    candidates = allowed_runner_identifiers_for_agent_runs
    return fallback_identifier if candidates.length < 2 || runner_selection_mode == "single"

    case runner_selection_mode
    when "random"
      pick_random_runner_identifier(candidates) || fallback_identifier
    when "round_robin"
      pick_round_robin_runner_identifier(candidates) || fallback_identifier
    else
      fallback_identifier
    end
  end

  alias_method :select_automated_provider_identifier, :select_automated_runner_identifier

  def runner_priority_for_goal(goal, identifiers: false)
    goal_identifier = default_runner_identifier_for_goal(goal)
    default = goal_identifier.present? ? [ goal_identifier ] : []
    priorities = default + fallback_priority_for(
      primary_runner: goal_identifier || default_agent_runner,
      identifiers: true
    )

    return priorities if identifiers

    map_identifiers_to_runner_keys(priorities)
  end

  alias_method :provider_priority_for_goal, :runner_priority_for_goal

  def sanitize_runner_tokens(tokens, candidates:)
    Array(tokens).flat_map do |token|
      token = token.to_s
      next [] if token.blank?
      next token if candidates.include?(token)
      resolved = identifiers_for_runner_token(token, candidates: candidates)
      next resolved if resolved.any?

      []
    end.uniq
  end

  def fallback_priority_for(primary_runner: nil, primary_provider: nil, identifiers: false)
    current_primary = primary_runner || primary_provider

    candidates = allowed_runner_identifiers_for_fallback
    saved_order = Array(fallback_runners).flat_map do |runner|
      identifiers_for_runner_token(runner, candidates: candidates)
    end
    ordered_candidates = (saved_order + (candidates - saved_order)).uniq
    primary_identifiers = identifiers_for_runner_token(current_primary, candidates: ordered_candidates)
    primary_index = saved_order.index { |runner| primary_identifiers.include?(runner) || runner == current_primary }
    rotated_candidates = primary_index ? ordered_candidates.rotate(primary_index + 1) : ordered_candidates
    priorities = rotated_candidates.reject { |runner| primary_identifiers.include?(runner) || runner == current_primary }
    return priorities if identifiers

    map_identifiers_to_runner_keys(priorities)
  end

  # Returns runners that are currently available (not rate limited, circuit not open).
  # Checks RunnerState for each runner and filters out unavailable ones.
  #
  # @param check_circuit_recovery [Boolean] Whether to check for circuit recovery before filtering
  # @return [Array<String>] Available runner names in priority order
  def available_runners(check_circuit_recovery: true, identifiers: false)
    priorities = runner_priority(identifiers: true)
    runner_keys_by_identifier = priorities.index_with do |identifier|
      runner_key_for_identifier(identifier)
    end
    runner_keys = runner_keys_by_identifier.values.uniq
    states_by_name = user.runner_states.where(runner_name: priorities + runner_keys).index_by(&:runner_name)

    available = priorities.select do |runner|
      state = states_by_name[runner] || states_by_name[runner_keys_by_identifier[runner]]
      next true unless state

      # Check if circuit can recover before filtering
      state.check_circuit_recovery!(timeout: circuit_breaker_timeout_seconds) if check_circuit_recovery

      !state.unavailable?
    end

    return available if identifiers

    map_identifiers_to_runner_keys(available)
  end

  alias_method :available_providers, :available_runners

  # Returns the RunnerState for a given runner, creating one if it doesn't exist.
  #
  # @param runner_name [String] The runner name
  # @return [RunnerState]
  def runner_state_for(runner_name)
    user.runner_states.find_or_create_by!(runner_name: runner_name)
  rescue ActiveRecord::RecordNotUnique
    user.runner_states.find_by!(runner_name: runner_name)
  end

  alias_method :provider_state_for, :runner_state_for

  private

  def sync_legacy_provider_bridge_columns
    LEGACY_PROVIDER_ATTRIBUTE_BRIDGES.each do |legacy_name, runner_name|
      runner_value = self[runner_name]
      legacy_value = self[legacy_name]

      if will_save_change_to_attribute?(runner_name)
        self[legacy_name] = runner_value
      elsif will_save_change_to_attribute?(legacy_name)
        self[runner_name] = legacy_value
      elsif runner_value.nil? && !legacy_value.nil?
        self[runner_name] = legacy_value
      elsif legacy_value.nil? && !runner_value.nil?
        self[legacy_name] = runner_value
      end
    end
  end

  # Picks a candidate at random, weighted by each runner's weight column.
  # Falls back to uniform random when weights cannot be resolved (e.g. no
  # user attached for unsaved settings).
  def pick_random_runner_identifier(candidates)
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

  # Picks the next runner in round-robin order, repeating each runner
  # consecutively N times when its weight is N. Persists state on the
  # user_setting so subsequent calls advance the cursor.
  def pick_round_robin_runner_identifier(candidates)
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
  # runner's weight from the user's saved runners. Unknown identifiers
  # fall back to Runner::DEFAULT_WEIGHT so the cycle still advances.
  def weighted_candidate_pairs(candidates)
    weights_by_identifier = runner_weights_by_identifier(candidates)
    candidates.map do |identifier|
      [ identifier, weights_by_identifier.fetch(identifier, Runner::DEFAULT_WEIGHT) ]
    end
  end

  def runner_weights_by_identifier(candidates)
    return {} unless user
    return {} if user.new_record?

    routing_ids = candidates.filter_map { |identifier| Runner.id_from_routing_key(identifier) }
    return {} if routing_ids.empty?

    user.runners.kept_only.where(id: routing_ids).pluck(:id, :weight).to_h do |id, weight|
      [ "#{Runner::ROUTING_KEY_PREFIX}#{id}", weight || Runner::DEFAULT_WEIGHT ]
    end
  end

  # Returns a fingerprint for the current candidate ordering and weights so
  # the cursor resets when runners are added, removed, or re-weighted.
  def round_robin_fingerprint(weighted)
    weighted.map { |identifier, weight| "#{identifier}:#{weight}" }.join("|")
  end

  def round_robin_state_for(weighted)
    state = runner_round_robin_state.is_a?(Hash) ? runner_round_robin_state.dup : {}
    fingerprint = round_robin_fingerprint(weighted)
    state = {} if state["fingerprint"] != fingerprint
    state
  end

  def persist_round_robin_state!(state)
    return unless persisted?

    update_column(:runner_round_robin_state, state)
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.warn(
      message: "user_setting.round_robin_state_persist_failed",
      user_id: user_id,
      error: e.message
    )
  end

  def validate_fallback_runners
    return if fallback_runners.blank?

    unless fallback_runners.is_a?(Array)
      errors.add(:fallback_runners, "must be an array")
      return
    end

    self.fallback_runners = sanitize_runner_tokens(fallback_runners, candidates: allowed_runner_identifiers_for_fallback)
  end

  def validate_kb_embedding_runner
    self.kb_embedding_runner = normalize_kb_runner(kb_embedding_runner, default: KB_EMBEDDING_RUNNER_DEFAULT)
    return if KB_EMBEDDING_RUNNERS.include?(kb_embedding_runner)

    errors.add(:kb_embedding_runner, "is not a supported knowledge embedding runner")
  end

  def validate_kb_embedding_fallback_runners
    self.kb_embedding_fallback_runners = normalize_kb_runner_list(
      kb_embedding_fallback_runners,
      attribute: :kb_embedding_fallback_runners,
      supported_runners: KB_EMBEDDING_RUNNERS
    )
  end

  def validate_kb_chat_runner
    self.kb_chat_runner = normalize_kb_runner(kb_chat_runner, default: KB_CHAT_RUNNER_DEFAULT)
    return if KB_CHAT_RUNNERS.include?(kb_chat_runner)

    errors.add(:kb_chat_runner, "is not a supported knowledge chat runner")
  end

  def validate_kb_chat_fallback_runners
    self.kb_chat_fallback_runners = normalize_kb_runner_list(
      kb_chat_fallback_runners,
      attribute: :kb_chat_fallback_runners,
      supported_runners: KB_CHAT_RUNNERS
    )
  end

  def validate_default_agent_runners_by_goal
    return if default_agent_runners_by_goal.blank?

    unless default_agent_runners_by_goal.is_a?(Hash)
      errors.add(:default_agent_runners_by_goal, "must be a hash")
      return
    end

    allowed_goals = AgentRun::GOALS
    allowed_runners = allowed_runner_identifiers_for_agent_runs
    normalized = {}

    default_agent_runners_by_goal.each do |goal, runner|
      goal = goal.to_s

      unless allowed_goals.include?(goal)
        errors.add(:default_agent_runners_by_goal, "contains invalid goal: #{goal}")
        next
      end

      next if runner.blank?

      resolved = identifiers_for_runner_token(runner.to_s, candidates: allowed_runners)
      if resolved.empty? && !allowed_runners.include?(runner.to_s)
        errors.add(:default_agent_runners_by_goal, "contains invalid runner for #{goal}")
        next
      end

      normalized[goal] = resolved.first || runner.to_s
    end

    self.default_agent_runners_by_goal = normalized
  end

  def validate_default_agent_runner
    allowed = allowed_runner_identifiers_for_agent_runs
    token = default_agent_runner.to_s
    normalized = normalized_default_agent_runner

    if token.present? && allowed.include?(token)
      self.default_agent_runner = token
      return
    end

    if normalized.present?
      self.default_agent_runner = normalized
      return
    end

    if allowed.any?
      self.default_agent_runner = allowed.first
      return
    end

    errors.add(:default_agent_runner, "is not an enabled runner")
  end

  def allowed_runner_identifiers_for_agent_runs
    return self.class.enabled_agent_runners(nil, identifiers: true) unless user
    return self.class.enabled_agent_runners(user, identifiers: true) if user.new_record?

    executable_keys = RunnerSupport.container_executable_runner_keys
    self.class.runner_identifiers_for(
      user.runners.kept_only.for_agent_runs.where(runner_key: executable_keys).ordered,
      identifiers: true
    )
  end

  def allowed_runner_identifiers_for_fallback
    return self.class.fallback_candidate_runners(nil, identifiers: true) unless user
    return self.class.fallback_candidate_runners(user, identifiers: true) if user.new_record?

    executable_keys = RunnerSupport.container_executable_runner_keys
    self.class.runner_identifiers_for(
      user.runners.kept_only.for_fallback.where(runner_key: executable_keys).ordered,
      identifiers: true
    )
  end

  def normalized_default_agent_runner
    identifiers_for_runner_token(default_agent_runner, candidates: allowed_runner_identifiers_for_agent_runs).first
  end

  def identifiers_for_runner_token(token, candidates:)
    token = token.to_s
    return [] if token.blank?

    exact = candidates.select { |candidate| candidate == token }
    return exact if exact.any?
    return [] unless user

    if Runner.routing_key?(token)
      runner_id = Runner.id_from_routing_key(token)
      return [] unless runner_id

      canonical_identifier = "#{Runner::ROUTING_KEY_PREFIX}#{runner_id}"
      return [ canonical_identifier ] if candidates.include?(canonical_identifier) &&
        user.runners.kept_only.exists?(id: runner_id)

      return [ token ] if candidates.include?(token) && user.runners.kept_only.exists?(id: runner_id)
    end

    runner_index_by_id = {}
    routing_ids = candidates.filter_map.with_index do |candidate, index|
      runner_id = Runner.id_from_routing_key(candidate)
      runner_index_by_id[runner_id] ||= index if runner_id
      runner_id
    end
    return [] if routing_ids.empty?

    matching_runners = user.runners.kept_only.where(id: routing_ids, runner_key: token).ordered.to_a
    return [] if matching_runners.empty?

    preferred_runner = matching_runners.min_by do |runner|
      [
        runner.subscription? ? 0 : 1,
        runner_index_by_id.fetch(runner.id, Float::INFINITY)
      ]
    end
    preferred_identifier = "#{Runner::ROUTING_KEY_PREFIX}#{preferred_runner.id}"

    candidates.include?(preferred_identifier) ? [ preferred_identifier ] : []
  end

  alias_method :identifiers_for_provider_token, :identifiers_for_runner_token

  def map_identifiers_to_runner_keys(identifiers)
    Array(identifiers).map do |identifier|
      runner_key_for_identifier(identifier)
    end.uniq
  end

  def runner_key_for_identifier(identifier)
    Runner.for_identifier(user, identifier)&.runner_key || identifier
  end

  def normalize_kb_runner(value, default:)
    value.to_s.strip.downcase.presence || default
  end

  def normalize_kb_runner_list(value, attribute:, supported_runners: nil)
    return [] if value.nil?

    unless value.is_a?(Array)
      errors.add(attribute, "must be an array")
      return value
    end

    normalized = value.filter_map do |runner|
      runner.to_s.strip.downcase.presence
    end.uniq

    return normalized unless supported_runners

    unsupported = normalized - supported_runners
    if unsupported.any?
      errors.add(attribute, "contains unsupported runners: #{unsupported.join(', ')}")
    end

    normalized
  end

  def validate_max_concurrent_runs_for_mode
    return unless run_concurrency_manual? && max_concurrent_runs.blank?

    errors.add(:max_concurrent_runs, "must be set in manual run concurrency mode")
  end

  def self.runner_identifiers_for(runners, identifiers:)
    if identifiers
      runners.pluck(:id).map { |id| "#{Runner::ROUTING_KEY_PREFIX}#{id}" }
    else
      runners.pluck(:runner_key).uniq
    end
  end
end
