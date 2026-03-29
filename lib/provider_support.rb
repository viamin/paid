# frozen_string_literal: true

require "set"

module ProviderSupport
  # Maps app-level provider keys to agent-harness registry keys.
  # This drives validation, UI, and configuration — providers listed here are
  # "known" to the app and can be configured by users.
  #
  # NOTE: Inclusion here does NOT mean the provider's CLI is installed in the
  # agent Docker container. For container execution, see CONTAINER_EXECUTABLE_PROVIDER_KEYS.
  APP_TO_HARNESS_PROVIDER_KEYS = {
    "claude" => "claude",
    "cursor" => "cursor",
    "codex" => "codex",
    "copilot" => "github_copilot",
    "aider" => "aider",
    "gemini" => "gemini",
    "opencode" => "opencode",
    "kilocode" => "kilocode"
  }.freeze

  # Provider keys whose CLIs are actually installed in the agent Docker container
  # (docker/agent/Dockerfile). Only these providers can execute in container-based
  # runs. Currently Claude CLI, Codex CLI, Cursor agent CLI, Gemini CLI,
  # Kilocode CLI, OpenCode CLI, GitHub Copilot CLI, and Aider CLI are installed
  # in the container image. Update this list when new CLIs are added to the Dockerfile.
  CONTAINER_EXECUTABLE_PROVIDER_KEYS = Set.new(%w[aider claude codex copilot cursor gemini kilocode opencode]).freeze

  module_function

  # Returns supported provider keys in a deterministic order matching
  # APP_TO_HARNESS_PROVIDER_KEYS declaration order, so that provider
  # priority and default selection are stable across boots.
  def supported_provider_keys
    APP_TO_HARNESS_PROVIDER_KEYS.keys.select { |key| supported_provider_keys_set.include?(key) }
  end

  def supported_provider_key?(provider_key)
    supported_provider_keys_set.include?(provider_key.to_s)
  end

  def supported_provider_keys_set
    @supported_provider_keys_set ||= begin
      registry_keys = AgentHarness::Providers::Registry.instance.all.map(&:to_s).to_set

      APP_TO_HARNESS_PROVIDER_KEYS.each_with_object(Set.new) do |(provider_key, harness_key), set|
        set << provider_key if registry_keys.include?(harness_key)
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
    APP_TO_HARNESS_PROVIDER_KEYS.fetch(provider_key.to_s, provider_key.to_s)
  end

  def provider_key_for_agent_type(agent_type)
    return "claude" if agent_type.to_s == "claude_code"

    agent_type.to_s
  end

  def agent_type_for(provider_key)
    return "claude_code" if provider_key.to_s == "claude"

    provider_key.to_s
  end

  def container_execution_flags_for(provider_key)
    CONTAINER_EXECUTION_FLAGS.fetch(provider_key.to_s, [])
  end

  def subscription_auth_unset_vars_for(provider_key)
    SUBSCRIPTION_AUTH_UNSET_VARS.fetch(provider_key.to_s, [])
  end

  def subscription_auth_unset_vars
    SUBSCRIPTION_AUTH_UNSET_VARS
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

  # Returns true if the given login matches a known bot username for the
  # specified provider key.
  def provider_bot_username_for?(provider_key, login)
    return false if login.blank?

    usernames = PROVIDER_BOT_USERNAMES[provider_key.to_s]
    return false unless usernames

    usernames.include?(login.downcase)
  end

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
    ].freeze
  }.freeze

  # Provider-specific CLI flags required for container execution.
  # These flags ensure providers run correctly inside Paid's isolated Docker
  # containers. For example, Codex needs its inner sandbox disabled because
  # the container already provides isolation via Docker namespaces.
  #
  # TODO(#595): Move container execution flag knowledge upstream to
  # agent-harness (see viamin/agent-harness#48). Once that lands, source
  # these flags from the harness provider configuration and remove this constant.
  CONTAINER_EXECUTION_FLAGS = {
    "codex" => %w[--dangerously-bypass-approvals-and-sandbox].freeze
  }.freeze

  # Environment variables to unset when running a provider with its own
  # subscription auth (so the agent talks directly to the provider instead of
  # through the Paid proxy). Shared between RunAgentActivity and TestAgent to
  # keep runtime and test paths in sync.
  SUBSCRIPTION_AUTH_UNSET_VARS = {
    "codex" => %w[
      OPENAI_API_KEY
      OPENAI_BASE_URL
      OPENAI_HEADER_X_AGENT_RUN_ID
      OPENAI_HEADER_X_PROXY_TOKEN
    ].freeze,
    "gemini" => %w[
      GEMINI_API_KEY
      GOOGLE_GEMINI_BASE_URL
      GOOGLE_GENAI_BASE_URL
      GOOGLE_HEADER_X_AGENT_RUN_ID
      GOOGLE_HEADER_X_PROXY_TOKEN
      GEMINI_CLI_CUSTOM_HEADERS
    ].freeze
  }.freeze
end
