# frozen_string_literal: true

require "set"

module RunnerSupport
  # App-level runner keys in priority/declaration order.
  # These are the runner identifiers "known" to the app and configurable by
  # users.  Harness-canonical names (e.g. "github_copilot" for "copilot") are
  # resolved at runtime via the agent-harness registry, eliminating the need
  # for a local mapping hash that can drift from upstream.
  #
  # NOTE: Inclusion here does NOT mean the runner's CLI is installed in the
  # agent Docker container. For container execution, see CONTAINER_EXECUTABLE_RUNNER_KEYS.
  APP_RUNNER_KEYS = %w[claude cursor codex copilot aider gemini opencode kilocode pi].freeze

  # Runner keys whose CLIs are actually installed in the agent Docker container
  # and can execute repository-changing agent tasks. GitHub Copilot CLI is
  # included via its --autopilot mode which enables fully autonomous,
  # non-interactive agent execution.
  CONTAINER_EXECUTABLE_RUNNER_KEYS = Set.new(%w[aider claude codex copilot cursor gemini kilocode opencode pi]).freeze

  module_function

  # Returns supported runner keys in a deterministic order matching
  # APP_RUNNER_KEYS declaration order, so that runner priority and
  # default selection are stable across boots.
  def supported_runner_keys
    APP_RUNNER_KEYS.select { |key| supported_runner_keys_set.include?(key) }
  end

  def supported_runner_key?(runner_key)
    supported_runner_keys_set.include?(runner_key.to_s)
  end

  def supported_runner_keys_set
    @supported_runner_keys_set ||= begin
      registered = AgentHarness.providers
      APP_RUNNER_KEYS.each_with_object(Set.new) do |runner_key, set|
        metadata = AgentHarness.provider_metadata(runner_key.to_sym)
        canonical = metadata&.dig(:canonical_provider)
        set << runner_key if canonical && registered.include?(canonical)
      rescue AgentHarness::ConfigurationError, KeyError
        # Runner unknown/removed upstream — treat as unsupported.
        nil
      end.freeze
    end
  end

  def reset_supported_runner_keys!
    @supported_runner_keys_set = nil
  end

  def container_executable_runner_keys
    supported_runner_keys.select { |key| CONTAINER_EXECUTABLE_RUNNER_KEYS.include?(key) }
  end

  def container_executable_runner_key?(runner_key)
    container_executable_runner_keys.include?(runner_key.to_s)
  end

  # Returns runners that are both known to the app and runnable inside the
  # prebuilt paid-agent image. These are the only runners that should be
  # offered in the UI for new runner records, because the product contract is
  # that added runners must be usable for agent runs and fallback once saved.
  def addable_runner_keys
    container_executable_runner_keys
  end

  def addable_runner_key?(runner_key)
    addable_runner_keys.include?(runner_key.to_s)
  end

  def harness_runner_key_for(runner_key)
    metadata = AgentHarness.provider_metadata(runner_key.to_sym)
    metadata.fetch(:canonical_provider).to_s
  rescue KeyError
    raise AgentHarness::ConfigurationError,
      "provider_metadata for #{runner_key.inspect} missing :canonical_provider key"
  end

  def runner_key_for_agent_type(agent_type)
    return "claude" if agent_type.to_s == "claude_code"

    agent_type.to_s
  end

  def agent_type_for(runner_key)
    return "claude_code" if runner_key.to_s == "claude"

    runner_key.to_s
  end

  def api_service_types
    API_SERVICE_TYPES
  end

  def api_service_type_for(runner_key)
    RUNNER_API_SERVICE_TYPE[runner_key.to_s]
  end

  def api_service_type_label(service_type)
    API_SERVICE_TYPES.fetch(service_type.to_s, service_type.to_s.titleize)
  end

  def subscription_auth_unset_vars_for(runner_key)
    key = runner_key.to_s
    return [] unless APP_RUNNER_KEYS.include?(key)

    # Intentionally no rescue — if the harness runner is misconfigured or
    # renamed upstream, we want AgentHarness::ConfigurationError to propagate
    # so subscription auth failures are loud rather than silently degraded.
    harness_key = harness_runner_key_for(key).to_sym
    harness_vars = AgentHarness.provider(harness_key).subscription_unset_vars
    proxy_vars = PROXY_HEADER_UNSET_VARS.fetch(key, [])
    (harness_vars + proxy_vars).uniq
  end

  def subscription_auth_unset_vars
    CONTAINER_EXECUTABLE_RUNNER_KEYS.each_with_object({}) do |key, hash|
      vars = subscription_auth_unset_vars_for(key)
      hash[key] = vars if vars.any?
    end
  end

  # Returns the proxy API key name (e.g. :openai, :google) for a runner
  # that supports harness-based health checks, or nil if the runner
  # requires a full container test instead.
  def proxy_health_check_api_key_for(runner_key)
    PROXY_HEALTH_CHECK_API_KEYS[runner_key.to_s]
  end

  # Returns true if the given login matches a known runner bot username.
  def runner_bot_username?(login)
    return false if login.blank?

    normalized = login.downcase
    RUNNER_BOT_USERNAMES.any? { |_runner, usernames| usernames.include?(normalized) }
  end

  def all_bot_usernames
    RUNNER_BOT_USERNAMES.values.flatten.map(&:downcase).to_set
  end

  def runner_key_for_bot_username(login)
    return nil if login.blank?

    normalized = login.downcase
    RUNNER_BOT_USERNAMES.find { |_runner, usernames| usernames.include?(normalized) }&.first
  end

  def runner_bot_usernames_for(runner_key)
    RUNNER_BOT_USERNAMES.fetch(runner_key.to_s, []).map(&:downcase).to_set
  end

  # Returns true if the given login matches a known bot username for the
  # specified runner key.
  def runner_bot_username_for?(runner_key, login)
    return false if login.blank?

    usernames = RUNNER_BOT_USERNAMES[runner_key.to_s]
    return false unless usernames

    usernames.include?(login.downcase)
  end

  # Valid API service types that ProviderApiKey records can declare.
  # Each entry maps a service identifier to its human-readable label.
  API_SERVICE_TYPES = {
    "anthropic" => "Anthropic",
    "openai" => "OpenAI",
    "openrouter" => "OpenRouter",
    "google" => "Google AI",
    "inception" => "InceptionLabs",
    "deepseek" => "DeepSeek",
    "mistral" => "Mistral",
    "xai" => "xAI",
    "zai" => "z.ai",
    "zai_coding" => "z.ai (Coding Plan)"
  }.freeze

  # Maps each runner key to the upstream API service type its CLI tool
  # communicates with. Runners with a single, fixed API key type are listed
  # here. Runners that support multiple upstream API providers (opencode,
  # kilocode) determine their required key type dynamically — see
  # Runner#required_api_service_type.
  #
  # Runners NOT listed here (e.g. copilot, opencode, kilocode) either have
  # no compatible API key type (subscription-only) or resolve their required
  # key type dynamically based on a user-chosen api_provider.
  RUNNER_API_SERVICE_TYPE = {
    "claude" => "anthropic",
    "cursor" => "anthropic",
    "codex" => "openai",
    "aider" => "anthropic",
    "gemini" => "google"
  }.freeze

  # Reverse mapping: API service type → harness runner key.
  # Used by the secrets proxy to delegate token extraction to the correct
  # agent-harness provider class based on the proxy route.  Harness canonical
  # names are resolved via the registry at load time.
  API_SERVICE_TYPE_TO_HARNESS_KEY = RUNNER_API_SERVICE_TYPE
    .each_with_object({}) { |(runner_key, service_type), map| map[service_type] ||= runner_key }
    .transform_values { |pk| AgentHarness.provider_metadata(pk.to_sym)[:canonical_provider].to_s }
    .freeze

  # Maps runner keys to their upstream proxy API key name (used by
  # harness-based health checks). Runners listed here can be health-checked
  # via AgentHarness.check_provider when the corresponding API key is
  # configured, instead of spinning up a full container test run.
  PROXY_HEALTH_CHECK_API_KEYS = {
    "codex" => :openai,
    "gemini" => :google
  }.freeze

  # Bot usernames associated with each runner, used for filtering automated
  # review comments during PR scanning. Centralised here so that
  # ScanPaidPrsActivity does not hard-code runner-specific usernames.
  RUNNER_BOT_USERNAMES = {
    "copilot" => %w[
      copilot
      copilot[bot]
      copilot-pull-request-reviewer
      copilot-pull-request-reviewer[bot]
    ].freeze,
    "claude" => %w[
      claude[bot]
      claude-code[bot]
    ].freeze,
    "codex" => %w[
      chatgpt-codex-connector
      chatgpt-codex-connector[bot]
    ].freeze,
    "paid_agent" => %w[
      paid-code-reviewer
      paid-code-reviewer[bot]
    ].freeze
  }.freeze

  # Proxy-specific header env vars that Paid sets but agent-harness does not
  # know about. These must be unset alongside the runner-native vars from
  # agent-harness when running in subscription-auth mode.
  PROXY_HEADER_UNSET_VARS = {
    "gemini" => %w[
      GOOGLE_HEADER_X_AGENT_RUN_ID
      GOOGLE_HEADER_X_PROXY_TOKEN
    ].freeze,
    "codex" => %w[
      OPENAI_HEADER_X_AGENT_RUN_ID
      OPENAI_HEADER_X_PROXY_TOKEN
    ].freeze
  }.freeze

  # Environment variables to unset when a runner runs via the agent-harness
  # execution plan (direct outbound). These proxy-specific headers are
  # inherited from container startup but must not leak to the real provider
  # API. Keyed by runner_key, same pattern as SUBSCRIPTION_AUTH_UNSET_VARS.
  HARNESS_RUNTIME_UNSET_VARS = {
    "opencode" => %w[
      OPENAI_HEADER_X_AGENT_RUN_ID
      OPENAI_HEADER_X_PROXY_TOKEN
    ].freeze
  }.freeze

  # Returns an AgentHarness provider instance for the given API service type
  # (e.g. "anthropic", "openai", "google") as used by the secrets proxy routes.
  def harness_provider_for_api_service_type(api_service_type)
    harness_key = API_SERVICE_TYPE_TO_HARNESS_KEY.fetch(api_service_type.to_s)
    AgentHarness.provider(harness_key.to_sym)
  end

  def harness_runtime_unset_vars_for(runner_key)
    HARNESS_RUNTIME_UNSET_VARS.fetch(runner_key.to_s, [])
  end

  # Wraps a command with `env -u` to strip the given environment variables.
  # Shared by RunAgentActivity and TestAgent to keep runtime and test paths in sync.
  def command_with_unset_env(command, unset_vars)
    return command if unset_vars.empty?

    if command.is_a?(Array)
      [ "env", *unset_vars.flat_map { |var| [ "-u", var ] }, *command ]
    else
      unset_flags = unset_vars.map { |var| "-u #{var}" }.join(" ")
      [ "sh", "-c", "env #{unset_flags} #{command}" ]
    end
  end

  # Returns an AgentHarness provider instance for the given app-level runner key.
  def harness_for(runner_key)
    harness_key = harness_runner_key_for(runner_key).to_sym
    AgentHarness.provider(harness_key)
  end

  # Normalizes common rate-limit reset text patterns before parsing.
  # Shared by RunAgentActivity and TestAgent so normalization stays in sync.
  def normalized_rate_limit_reset_text(text)
    text.to_s
      .gsub(/retry.?after:?\s*(\d+)(?!\s*s)/i, 'retry after \1s')
      .gsub(/reset.?at:?\s*(\d+)/i, 'reset at \1')
  end

  # Parses a rate-limit reset time from runner output using the given
  # harness provider. Falls back to normalized text parsing and a 1-hour
  # default. Shared by RunAgentActivity and TestAgent.
  def rate_limit_reset_at(harness_provider, text)
    parsed_reset = harness_provider.parse_rate_limit_reset(text.to_s) ||
      harness_provider.parse_rate_limit_reset(normalized_rate_limit_reset_text(text)) ||
      1.hour.from_now
    parsed_reset > Time.current ? parsed_reset : 1.hour.from_now
  rescue AgentHarness::ConfigurationError, KeyError
    1.hour.from_now
  end

  # Returns error_classification_patterns[category] for a single runner.
  def error_classification_patterns_for(runner_key, category)
    harness_for(runner_key).error_classification_patterns.fetch(category, [])
  rescue AgentHarness::ConfigurationError, KeyError
    []
  end

  # Aggregates error_classification_patterns[category] across all supported runners.
  def aggregated_error_classification_patterns(category)
    supported_runner_keys.flat_map { |key| error_classification_patterns_for(key, category) }.uniq
  end

  # Aggregates noisy_error_patterns across all supported runners.
  def aggregated_noisy_error_patterns
    supported_runner_keys.flat_map do |key|
      harness_for(key).noisy_error_patterns
    rescue AgentHarness::ConfigurationError, KeyError
      []
    end.uniq
  end

  # Translates a raw error message using the given runner's translate_error.
  # Returns nil if the runner does not translate the message (returns it unchanged).
  def translate_runner_error(runner_key, message)
    translated = harness_for(runner_key).translate_error(message)
    translated == message ? nil : translated
  rescue AgentHarness::ConfigurationError, KeyError
    nil
  end
end
