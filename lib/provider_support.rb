# frozen_string_literal: true

require "set"

module ProviderSupport
  # App-level provider keys in priority/declaration order.
  # These are the provider identifiers "known" to the app and configurable by
  # users.  Harness-canonical names (e.g. "github_copilot" for "copilot") are
  # resolved at runtime via the agent-harness registry, eliminating the need
  # for a local mapping hash that can drift from upstream.
  #
  # NOTE: Inclusion here does NOT mean the provider's CLI is installed in the
  # agent Docker container. For container execution, see CONTAINER_EXECUTABLE_PROVIDER_KEYS.
  APP_PROVIDER_KEYS = %w[claude cursor codex copilot aider gemini opencode kilocode pi].freeze

  # Provider keys whose CLIs are actually installed in the agent Docker container
  # and can execute repository-changing agent tasks. GitHub Copilot CLI is
  # included via its --autopilot mode which enables fully autonomous,
  # non-interactive agent execution.
  CONTAINER_EXECUTABLE_PROVIDER_KEYS = Set.new(%w[aider claude codex copilot cursor gemini kilocode opencode pi]).freeze

  # Upper bound on how far in the future a parsed rate-limit reset is trusted.
  #
  # WORKAROUND (remove when agent-harness reset parsing is fixed): the gem's
  # shared "resets <Mon> <day>" parser infers the year by month comparison
  # (`year += 1 if month < current_month`), so a reset like "resets Jan 15"
  # seen mid-year is read as ~10-11 months out. Codex emits these, and the
  # bogus far-future value benches the provider for months. No real provider
  # rate-limit window exceeds a week (Codex's longest is its weekly cap), so
  # anything past this ceiling is a parse error, not a real reset.
  #
  # Expressed in plain seconds (not 8.days) because this file is loaded by the
  # agent-image runner-contract smoke test without ActiveSupport, where the
  # Integer#days extension is unavailable.
  MAX_RATE_LIMIT_RESET_SECONDS = 8 * 24 * 60 * 60

  module_function

  # Returns supported provider keys in a deterministic order matching
  # APP_PROVIDER_KEYS declaration order, so that provider priority and
  # default selection are stable across boots.
  def supported_provider_keys
    APP_PROVIDER_KEYS.select { |key| supported_provider_keys_set.include?(key) }
  end

  def supported_provider_key?(provider_key)
    supported_provider_keys_set.include?(provider_key.to_s)
  end

  def supported_provider_keys_set
    @supported_provider_keys_set ||= begin
      registered = AgentHarness.providers
      APP_PROVIDER_KEYS.each_with_object(Set.new) do |provider_key, set|
        metadata = AgentHarness.provider_metadata(provider_key.to_sym)
        canonical = metadata&.dig(:canonical_provider)
        set << provider_key if canonical && registered.include?(canonical)
      rescue AgentHarness::ConfigurationError, KeyError
        # Provider unknown/removed upstream — treat as unsupported.
        nil
      end.freeze
    end
  end

  def reset_supported_provider_keys!
    @supported_provider_keys_set = nil
  end

  def container_executable_provider_keys
    supported_provider_keys.select { |key| CONTAINER_EXECUTABLE_PROVIDER_KEYS.include?(key) }
  end

  def container_executable_provider_key?(provider_key)
    container_executable_provider_keys.include?(provider_key.to_s)
  end

  # Returns providers that are both known to the app and runnable inside the
  # prebuilt paid-agent image. These are the only providers that should be
  # offered in the UI for new provider records, because the product contract is
  # that added providers must be usable for agent runs and fallback once saved.
  def addable_provider_keys
    container_executable_provider_keys
  end

  def addable_provider_key?(provider_key)
    addable_provider_keys.include?(provider_key.to_s)
  end

  def harness_provider_key_for(provider_key)
    metadata = AgentHarness.provider_metadata(provider_key.to_sym)
    metadata.fetch(:canonical_provider).to_s
  rescue KeyError
    raise AgentHarness::ConfigurationError,
      "provider_metadata for #{provider_key.inspect} missing :canonical_provider key"
  end

  def provider_key_for_agent_type(agent_type)
    return "claude" if agent_type.to_s == "claude_code"

    agent_type.to_s
  end

  def agent_type_for(provider_key)
    return "claude_code" if provider_key.to_s == "claude"

    provider_key.to_s
  end

  def api_service_types
    API_SERVICE_TYPES
  end

  def api_service_type_for(provider_key)
    PROVIDER_API_SERVICE_TYPE[provider_key.to_s]
  end

  def api_service_type_label(service_type)
    API_SERVICE_TYPES.fetch(service_type.to_s, service_type.to_s.titleize)
  end

  def subscription_auth_unset_vars_for(provider_key)
    key = provider_key.to_s
    return [] unless APP_PROVIDER_KEYS.include?(key)

    # Intentionally no rescue — if the harness provider is misconfigured or
    # renamed upstream, we want AgentHarness::ConfigurationError to propagate
    # so subscription auth failures are loud rather than silently degraded.
    harness_key = harness_provider_key_for(key).to_sym
    harness_vars = AgentHarness.provider(harness_key).subscription_unset_vars
    proxy_vars = PROXY_HEADER_UNSET_VARS.fetch(key, [])
    (harness_vars + proxy_vars).uniq
  end

  def subscription_auth_unset_vars
    CONTAINER_EXECUTABLE_PROVIDER_KEYS.each_with_object({}) do |key, hash|
      vars = subscription_auth_unset_vars_for(key)
      hash[key] = vars if vars.any?
    end
  end

  # Returns the proxy API key name (e.g. :openai, :google) for a provider
  # that supports harness-based health checks, or nil if the provider
  # requires a full container test instead.
  def proxy_health_check_api_key_for(provider_key)
    PROXY_HEALTH_CHECK_API_KEYS[provider_key.to_s]
  end

  # Returns true if the given login matches a known provider bot username.
  def provider_bot_username?(login)
    return false if login.blank?

    normalized = login.downcase
    PROVIDER_BOT_USERNAMES.any? { |_provider, usernames| usernames.include?(normalized) }
  end

  def all_bot_usernames
    PROVIDER_BOT_USERNAMES.values.flatten.map(&:downcase).to_set
  end

  def provider_key_for_bot_username(login)
    return nil if login.blank?

    normalized = login.downcase
    PROVIDER_BOT_USERNAMES.find { |_provider, usernames| usernames.include?(normalized) }&.first
  end

  def provider_bot_usernames_for(provider_key)
    PROVIDER_BOT_USERNAMES.fetch(provider_key.to_s, []).map(&:downcase).to_set
  end

  # Returns true if the given login matches a known bot username for the
  # specified provider key.
  def provider_bot_username_for?(provider_key, login)
    return false if login.blank?

    usernames = PROVIDER_BOT_USERNAMES[provider_key.to_s]
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
    "minimax" => "MiniMax",
    "xai" => "xAI",
    "zai" => "z.ai",
    "zai_coding" => "z.ai (Coding Plan)"
  }.freeze

  # Maps each provider key to the upstream API service type its CLI tool
  # communicates with. Providers with a single, fixed API key type are listed
  # here. Providers that support multiple upstream API providers (opencode,
  # kilocode) determine their required key type dynamically — see
  # Provider#required_api_service_type.
  #
  # Providers NOT listed here (e.g. copilot, opencode, kilocode) either have
  # no compatible API key type (subscription-only) or resolve their required
  # key type dynamically based on a user-chosen api_provider.
  PROVIDER_API_SERVICE_TYPE = {
    "claude" => "anthropic",
    "cursor" => "anthropic",
    "codex" => "openai",
    "aider" => "anthropic",
    "gemini" => "google"
  }.freeze

  # Reverse mapping: API service type → harness provider key.
  # Used by the secrets proxy to delegate token extraction to the correct
  # agent-harness provider class based on the proxy route.  Harness canonical
  # names are resolved via the registry at load time.
  API_SERVICE_TYPE_TO_HARNESS_KEY = PROVIDER_API_SERVICE_TYPE
    .each_with_object({}) { |(provider_key, service_type), map| map[service_type] ||= provider_key }
    .transform_values { |pk| AgentHarness.provider_metadata(pk.to_sym)[:canonical_provider].to_s }
    .freeze

  # Maps provider keys to their upstream proxy API key name (used by
  # harness-based health checks). Providers listed here can be health-checked
  # via AgentHarness.check_provider when the corresponding API key is
  # configured, instead of spinning up a full container test run.
  PROXY_HEALTH_CHECK_API_KEYS = {
    "codex" => :openai,
    "gemini" => :google
  }.freeze

  # Bot usernames associated with each provider, used for filtering automated
  # review comments during PR scanning. Centralised here so that
  # ScanPaidPrsActivity does not hard-code provider-specific usernames.
  PROVIDER_BOT_USERNAMES = {
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
  # know about. These must be unset alongside the provider-native vars from
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

  # Environment variables to unset when a provider runs via the agent-harness
  # execution plan (direct outbound). These proxy-specific headers are
  # inherited from container startup but must not leak to the real provider
  # API. Keyed by provider_key, same pattern as SUBSCRIPTION_AUTH_UNSET_VARS.
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

  def harness_runtime_unset_vars_for(provider_key)
    HARNESS_RUNTIME_UNSET_VARS.fetch(provider_key.to_s, [])
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

  # Returns an AgentHarness provider instance for the given app-level provider key.
  def harness_provider_for(provider_key)
    harness_key = harness_provider_key_for(provider_key).to_sym
    AgentHarness.provider(harness_key)
  end

  # Normalizes common rate-limit reset text patterns before parsing.
  # Shared by RunAgentActivity and TestAgent so normalization stays in sync.
  def normalized_rate_limit_reset_text(text)
    text.to_s
      .gsub(/retry.?after:?\s*(\d+)(?!\s*s)/i, 'retry after \1s')
      .gsub(/reset.?at:?\s*(\d+)/i, 'reset at \1')
  end

  # Parses a rate-limit reset time from provider output using the given
  # harness provider. Falls back to normalized text parsing and a 1-hour
  # default. Shared by RunAgentActivity and TestAgent.
  def rate_limit_reset_at(harness_provider, text)
    parsed_reset = harness_provider.parse_rate_limit_reset(text.to_s) ||
      harness_provider.parse_rate_limit_reset(normalized_rate_limit_reset_text(text)) ||
      1.hour.from_now
    return 1.hour.from_now unless parsed_reset > Time.current

    # Reject implausibly far-future resets from upstream parse bugs (see
    # MAX_RATE_LIMIT_RESET_SECONDS); fall back to the conservative default so
    # the next attempt re-detects the real limit instead of benching for months.
    # Logged so operators can see the workaround firing and know when the
    # upstream fix has landed (clamp stops triggering => safe to remove).
    if parsed_reset > MAX_RATE_LIMIT_RESET_SECONDS.seconds.from_now
      Rails.logger.warn(
        message: "runner_support.rate_limit_reset_clamped",
        provider: harness_provider.class.name,
        parsed_reset_at: parsed_reset.utc.iso8601,
        max_reset_seconds: MAX_RATE_LIMIT_RESET_SECONDS
      )
      return 1.hour.from_now
    end

    parsed_reset
  rescue AgentHarness::ConfigurationError, KeyError
    1.hour.from_now
  end

  # Returns error_classification_patterns[category] for a single provider.
  def error_classification_patterns_for(provider_key, category)
    harness_provider_for(provider_key).error_classification_patterns.fetch(category, [])
  rescue AgentHarness::ConfigurationError, KeyError
    []
  end

  # Aggregates error_classification_patterns[category] across all supported providers.
  def aggregated_error_classification_patterns(category)
    supported_provider_keys.flat_map { |key| error_classification_patterns_for(key, category) }.uniq
  end

  # Aggregates noisy_error_patterns across all supported providers.
  def aggregated_noisy_error_patterns
    supported_provider_keys.flat_map do |key|
      harness_provider_for(key).noisy_error_patterns
    rescue AgentHarness::ConfigurationError, KeyError
      []
    end.uniq
  end

  # Translates a raw error message using the given provider's translate_error.
  # Returns nil if the provider does not translate the message (returns it unchanged).
  def translate_provider_error(provider_key, message)
    translated = harness_provider_for(provider_key).translate_error(message)
    translated == message ? nil : translated
  rescue AgentHarness::ConfigurationError, KeyError
    nil
  end
end
