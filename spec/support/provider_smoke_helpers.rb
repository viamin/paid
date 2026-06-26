# frozen_string_literal: true

require "json"
require "open3"

module ProviderSmokeHelpers
  Scenario = Struct.new(
    :name,
    :provider_key,
    :auth_type,
    :api_provider,
    :model_env,
    :default_model,
    :label,
    :diagnostic_prompt,
    :diagnostic_timeout,
    :diagnostic_success_pattern,
    keyword_init: true
  ) do
    def subscription?
      auth_type == "subscription"
    end

    def api_key?
      auth_type == "api_key"
    end

    def diagnostic?
      !diagnostic_prompt.nil?
    end
  end

  ScenarioUnavailableError = Class.new(StandardError)

  SERVICE_TYPE_ENV_VARS = {
    "anthropic" => "ANTHROPIC_API_KEY",
    "openai" => "OPENAI_API_KEY",
    "openrouter" => "OPENROUTER_API_KEY",
    "google" => "GOOGLE_API_KEY",
    "inception" => "INCEPTION_API_KEY",
    "deepseek" => "DEEPSEEK_API_KEY",
    "mistral" => "MISTRAL_API_KEY",
    "minimax" => "ANTHROPIC_API_KEY",
    "xai" => "XAI_API_KEY",
    "zai" => "ZAI_API_KEY",
    "zai_coding" => "ZAI_CODING_API_KEY"
  }.freeze
  DEFAULT_SCENARIO_NAMES = %w[
    claude-subscription
    codex-subscription
    copilot-subscription
    kilocode-zai
    opencode-openrouter
    kilocode-inception
  ].freeze
  SCENARIOS = {
    "claude-subscription" => Scenario.new(
      name: "claude-subscription",
      provider_key: "claude",
      auth_type: "subscription",
      label: "Claude subscription"
    ),
    "cursor-subscription" => Scenario.new(
      name: "cursor-subscription",
      provider_key: "cursor",
      auth_type: "subscription",
      label: "Cursor subscription"
    ),
    "codex-subscription" => Scenario.new(
      name: "codex-subscription",
      provider_key: "codex",
      auth_type: "subscription",
      label: "Codex subscription"
    ),
    "gemini-subscription" => Scenario.new(
      name: "gemini-subscription",
      provider_key: "gemini",
      auth_type: "subscription",
      label: "Gemini subscription"
    ),
    "aider-subscription" => Scenario.new(
      name: "aider-subscription",
      provider_key: "aider",
      auth_type: "subscription",
      label: "Aider subscription"
    ),
    "opencode-openrouter" => Scenario.new(
      name: "opencode-openrouter",
      provider_key: "opencode",
      auth_type: "api_key",
      api_provider: "openrouter",
      model_env: "PAID_SMOKE_OPENCODE_OPENROUTER_MODEL",
      default_model: "moonshotai/kimi-k2-0905",
      label: "OpenCode with OpenRouter API key"
    ),
    "opencode-minimax" => Scenario.new(
      name: "opencode-minimax",
      provider_key: "opencode",
      auth_type: "api_key",
      api_provider: "minimax",
      model_env: "PAID_SMOKE_OPENCODE_MINIMAX_MODEL",
      default_model: "MiniMax-M2.7",
      label: "OpenCode with MiniMax Token Plan API key"
    ),

    "kilocode-zai" => Scenario.new(
      name: "kilocode-zai",
      provider_key: "kilocode",
      auth_type: "api_key",
      api_provider: "zai_coding",
      model_env: "PAID_SMOKE_KILOCODE_ZAI_MODEL",
      default_model: "glm-5.2",
      label: "KiloCode with z.ai API key"
    ),
    "kilocode-inception" => Scenario.new(
      name: "kilocode-inception",
      provider_key: "kilocode",
      auth_type: "api_key",
      api_provider: "inception",
      model_env: "PAID_SMOKE_KILOCODE_INCEPTION_MODEL",
      default_model: "mercury-2",
      label: "KiloCode with Inception API key"
    ),
    "pi-deepseek" => Scenario.new(
      name: "pi-deepseek",
      provider_key: "pi",
      auth_type: "api_key",
      api_provider: "deepseek",
      model_env: "PAID_SMOKE_PI_DEEPSEEK_MODEL",
      default_model: "deepseek-chat",
      label: "Pi with DeepSeek API key"
    ),
    "pi-minimax" => Scenario.new(
      name: "pi-minimax",
      provider_key: "pi",
      auth_type: "api_key",
      api_provider: "minimax",
      model_env: "PAID_SMOKE_PI_MINIMAX_MODEL",
      default_model: "MiniMax-M2.7",
      label: "Pi with MiniMax Token Plan API key"
    ),
    "copilot-subscription" => Scenario.new(
      name: "copilot-subscription",
      provider_key: "copilot",
      auth_type: "subscription",
      label: "Copilot subscription"
    ),

    # Claude diagnostic scenarios — investigate why claude_code's real agent
    # runs sometimes hang for 5+ minutes with zero output. The default smoke
    # contract only sends "Reply OK" which always passes; these exercise the
    # heavier subsystems (tool use, longer reasoning) so when one diverges
    # from the baseline, the failure layer is isolated.
    #
    # Each runs inside the agent container, same path real runs take. Note
    # that the smoke `build_test_run` flow does NOT provision MCP servers,
    # so a true MCP-handshake scenario is out of scope here — it would need
    # to layer MCP server configuration onto the test container, which is
    # a deeper change than these scenarios are scoped for.
    "claude-diag-baseline" => Scenario.new(
      name: "claude-diag-baseline",
      provider_key: "claude",
      auth_type: "subscription",
      label: "Claude diagnostic: bare prompt",
      diagnostic_prompt: "Reply with exactly OK.",
      diagnostic_timeout: 60,
      diagnostic_success_pattern: /\AOK[.!]?\z/i
    ),
    "claude-diag-tool-required" => Scenario.new(
      name: "claude-diag-tool-required",
      provider_key: "claude",
      auth_type: "subscription",
      label: "Claude diagnostic: forces a tool call",
      # Forces at least one tool use before responding. The PostToolUse
      # heartbeat hook fires after this tool call — if this scenario hangs
      # but baseline passes, tool/permission initialization is the suspect.
      #
      # The success pattern keys on the literal sentinel "SMOKE_FS_CHECK"
      # which appears in the prompt. A model that hallucinates without
      # reading the filesystem might still produce that sentinel, but a
      # model whose tool path is broken cannot complete the instruction
      # (which requires concatenating with a real `uname` value) — so
      # failure-to-hang here is the diagnostic signal we care about.
      diagnostic_prompt: <<~PROMPT,
        Run `uname -s` using your shell tool, then reply with a single line
        in the format "SMOKE_FS_CHECK <uname_output>". Do not include any
        other text. If you cannot run a shell tool, reply exactly
        "SMOKE_FS_CHECK no-tools".
      PROMPT
      diagnostic_timeout: 120,
      diagnostic_success_pattern: /\ASMOKE_FS_CHECK \S+/
    )
  }.freeze
  CLAUDE_DIAGNOSTIC_SCENARIO_NAMES = %w[
    claude-diag-baseline
    claude-diag-tool-required
  ].freeze
  PRESETS = {
    "current-enabled" => nil,
    "all-scenarios" => SCENARIOS.keys,
    "claude-diagnostics" => CLAUDE_DIAGNOSTIC_SCENARIO_NAMES
  }.freeze

  module_function

  def scenario_names_from_env
    configured = ENV["PAID_SMOKE_SCENARIOS"].to_s.split(",").map(&:strip).reject(&:blank?)
    (configured.presence || [ "current-enabled" ]).flat_map { |name| expand_name(name) }
  end

  def scenarios_from_env
    scenario_names_from_env.map { |name| scenario_for(name) }
  end

  def scenario_for(name)
    SCENARIOS.fetch(name)
  rescue KeyError
    raise ScenarioUnavailableError, "Unknown provider smoke scenario #{name.inspect}"
  end

  def expand_name(name)
    return current_enabled_scenario_names if name == "current-enabled"

    PRESETS.fetch(name, [ name ])
  end

  def current_enabled_scenario_names
    DEFAULT_SCENARIO_NAMES | configured_scenario_names
  end

  def build_provider!(user:, scenario:)
    unless ProviderSupport.container_executable_provider_key?(scenario.provider_key)
      raise ScenarioUnavailableError,
        "#{scenario.label} is not runnable because #{scenario.provider_key} is not installed in the agent container"
    end

    if scenario.subscription?
      build_subscription_provider!(user: user, scenario: scenario)
    else
      build_direct_outbound_provider!(user: user, scenario: scenario)
    end
  end

  def build_subscription_provider!(user:, scenario:)
    user.providers.find_or_create_by!(provider_key: scenario.provider_key, auth_type: "subscription").tap do |provider|
      provider.update!(
        enabled_for_agent_runs: true,
        enabled_for_fallback: provider.enabled_for_fallback?
      )
    end
  end

  def build_direct_outbound_provider!(user:, scenario:)
    service_type = Provider::DIRECT_OUTBOUND_API_PROVIDERS.dig(scenario.api_provider, :service_type)
    if service_type.blank?
      raise ScenarioUnavailableError,
        "Unsupported #{scenario.provider_key} api provider #{scenario.api_provider.inspect} for #{scenario.label}"
    end

    dev_provider = development_provider_info_for(scenario)
    model_id = ENV[scenario.model_env].to_s.strip.presence ||
      dev_provider&.fetch("model", nil).to_s.presence ||
      scenario.default_model.presence
    if model_id.blank?
      raise ScenarioUnavailableError, "Set #{scenario.model_env} to run #{scenario.label}"
    end

    api_key = api_key_for_service_type(service_type, scenario: scenario, development_provider: dev_provider)
    if api_key.blank?
      raise ScenarioUnavailableError,
        "Set #{SERVICE_TYPE_ENV_VARS.fetch(service_type)} or create a matching provider/api key in the development DB to run #{scenario.label}"
    end

    KnownDirectOutboundModels.seed_model(model_id: model_id, provider: service_type)

    provider_api_key = FactoryBot.create(
      :provider_api_key,
      user: user,
      api_service_type: service_type,
      api_key: api_key,
      name: "#{scenario.name} key"
    )

    provider = user.providers.api_key.find_or_initialize_by(
      provider_key: scenario.provider_key,
      provider_api_key: provider_api_key,
      name: scenario.label
    )
    provider.assign_attributes(
      enabled_for_agent_runs: true,
      enabled_for_fallback: false,
      config: {
        scenario.provider_key => {
          "api_provider" => scenario.api_provider,
          "model" => model_id
        }
      }
    )
    provider.save!
    provider
  end

  def api_key_for_service_type(service_type, scenario:, development_provider: nil)
    env_var = SERVICE_TYPE_ENV_VARS.fetch(service_type)
    ENV[env_var].to_s.strip.presence ||
      development_provider&.fetch("api_key", nil).to_s.strip.presence
  end

  def create_smoke_project!(user:)
    account = user.account
    github_token = FactoryBot.create(:github_token, account: account, created_by: user)
    FactoryBot.create(:project, account: account, created_by: user, github_token: github_token)
  end

  def development_provider_info_for(scenario)
    @development_provider_info_cache ||= {}
    return @development_provider_info_cache[scenario.name] if @development_provider_info_cache.key?(scenario.name)

    service_type = Provider::DIRECT_OUTBOUND_API_PROVIDERS.dig(scenario.api_provider, :service_type)
    desired_model = ENV[scenario.model_env].to_s.strip.presence
    payload = {
      provider_key: scenario.provider_key,
      auth_type: scenario.auth_type,
      api_provider: scenario.api_provider,
      service_type: service_type,
      desired_model: desired_model
    }
    runner_script = <<~'RUBY'
      require "json"

      scenario = JSON.parse(ENV.fetch("PAID_SMOKE_SCENARIO_JSON"))

      result = TenantContext.with_system_access do
        candidates = Provider.includes(:provider_api_key)
          .where(provider_key: scenario.fetch("provider_key"), auth_type: scenario.fetch("auth_type"))
          .select do |provider|
            next false unless provider.provider_api_key&.api_service_type == scenario.fetch("service_type")

            config = provider.config.is_a?(Hash) ? provider.config.fetch(scenario.fetch("provider_key"), {}) : {}
            config["api_provider"].to_s == scenario.fetch("api_provider")
          end

        if candidates.empty?
          { found: false }
        else
          desired = scenario["desired_model"].to_s
          exact = desired.present? ? candidates.select { |provider|
            config = provider.config.is_a?(Hash) ? provider.config.fetch(scenario.fetch("provider_key"), {}) : {}
            config["model"].to_s == desired
          } : []
          chosen = exact.one? ? exact.first : candidates.first
          config = chosen.config.is_a?(Hash) ? chosen.config.fetch(scenario.fetch("provider_key"), {}) : {}

          {
            found: true,
            provider_name: chosen.name,
            api_key_name: chosen.provider_api_key&.name,
            api_key: chosen.provider_api_key&.api_key,
            model: config["model"],
            candidate_names: candidates.map { |provider| provider.name.presence || "provider ##{provider.id}" }
          }
        end
      end

      puts JSON.generate(result)
    RUBY

    stdout, _stderr, status = Open3.capture3(
      {
        "RAILS_ENV" => "development",
        "PAID_SMOKE_SCENARIO_JSON" => JSON.generate(payload)
      },
      "bundle", "exec", "rails", "runner", runner_script
    )

    return @development_provider_info_cache[scenario.name] = nil unless status.success?

    parsed = JSON.parse(stdout.lines.last.to_s)
    return @development_provider_info_cache[scenario.name] = nil unless parsed["found"]

    if parsed["candidate_names"].is_a?(Array) && parsed["candidate_names"].uniq.many? && parsed["model"].to_s != desired_model.to_s
      raise ScenarioUnavailableError,
        "Multiple development DB providers match #{scenario.label}: #{parsed['candidate_names'].join(', ')}. Set #{scenario.model_env} to disambiguate."
    end

    @development_provider_info_cache[scenario.name] = parsed
  rescue JSON::ParserError
    nil
  end

  def configured_scenario_names
    payload = configured_provider_payload
    return [] unless payload.is_a?(Array)

    payload.filter_map do |config|
      scenario_for_configuration(config)
    end.uniq
  end

  def configured_provider_payload
    @configured_provider_payload ||= begin
      runner_script = <<~'RUBY'
        require "json"

        result = TenantContext.with_system_access do
          Provider.includes(:provider_api_key)
            .where(auth_type: %w[subscription api_key])
            .map do |provider|
              config = provider.config.is_a?(Hash) ? provider.config.fetch(provider.provider_key, {}) : {}
              {
                "provider_key" => provider.provider_key,
                "auth_type" => provider.auth_type,
                "service_type" => provider.provider_api_key&.api_service_type,
                "api_provider" => config["api_provider"]
              }
            end
        end

        puts JSON.generate(result)
      RUBY

      stdout, _stderr, status = Open3.capture3(
        { "RAILS_ENV" => "development" },
        "bundle", "exec", "rails", "runner", runner_script
      )

      if status.success?
        JSON.parse(stdout.lines.last.to_s)
      else
        []
      end
    rescue JSON::ParserError
      []
    end
  end

  def scenario_for_configuration(config)
    SCENARIOS.each_value.find do |scenario|
      next false unless scenario.provider_key == config["provider_key"].to_s
      next false unless scenario.auth_type == config["auth_type"].to_s
      next true if scenario.subscription?

      service_type = Provider::DIRECT_OUTBOUND_API_PROVIDERS.dig(scenario.api_provider, :service_type)
      service_type == config["service_type"].to_s &&
        scenario.api_provider == config["api_provider"].to_s
    end&.name
  end
end
