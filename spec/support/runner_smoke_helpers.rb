# frozen_string_literal: true

require "json"
require "open3"

module RunnerSmokeHelpers
  Scenario = Struct.new(
    :name,
    :runner_key,
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
      runner_key: "claude",
      auth_type: "subscription",
      label: "Claude subscription"
    ),
    "cursor-subscription" => Scenario.new(
      name: "cursor-subscription",
      runner_key: "cursor",
      auth_type: "subscription",
      label: "Cursor subscription"
    ),
    "codex-subscription" => Scenario.new(
      name: "codex-subscription",
      runner_key: "codex",
      auth_type: "subscription",
      label: "Codex subscription"
    ),
    "gemini-subscription" => Scenario.new(
      name: "gemini-subscription",
      runner_key: "gemini",
      auth_type: "subscription",
      label: "Gemini subscription"
    ),
    "aider-subscription" => Scenario.new(
      name: "aider-subscription",
      runner_key: "aider",
      auth_type: "subscription",
      label: "Aider subscription"
    ),
    "opencode-openrouter" => Scenario.new(
      name: "opencode-openrouter",
      runner_key: "opencode",
      auth_type: "api_key",
      api_provider: "openrouter",
      model_env: "PAID_SMOKE_OPENCODE_OPENROUTER_MODEL",
      default_model: "moonshotai/kimi-k2",
      label: "OpenCode with OpenRouter API key"
    ),
    "opencode-minimax" => Scenario.new(
      name: "opencode-minimax",
      runner_key: "opencode",
      auth_type: "api_key",
      api_provider: "minimax",
      model_env: "PAID_SMOKE_OPENCODE_MINIMAX_MODEL",
      default_model: "MiniMax-M2.7",
      label: "OpenCode with MiniMax Token Plan API key"
    ),

    "kilocode-zai" => Scenario.new(
      name: "kilocode-zai",
      runner_key: "kilocode",
      auth_type: "api_key",
      api_provider: "zai_coding",
      model_env: "PAID_SMOKE_KILOCODE_ZAI_MODEL",
      default_model: "glm-5.1",
      label: "KiloCode with z.ai API key"
    ),
    "kilocode-inception" => Scenario.new(
      name: "kilocode-inception",
      runner_key: "kilocode",
      auth_type: "api_key",
      api_provider: "inception",
      model_env: "PAID_SMOKE_KILOCODE_INCEPTION_MODEL",
      default_model: "mercury-2",
      label: "KiloCode with Inception API key"
    ),
    "pi-deepseek" => Scenario.new(
      name: "pi-deepseek",
      runner_key: "pi",
      auth_type: "api_key",
      api_provider: "deepseek",
      model_env: "PAID_SMOKE_PI_DEEPSEEK_MODEL",
      default_model: "deepseek-chat",
      label: "Pi with DeepSeek API key"
    ),
    "pi-minimax" => Scenario.new(
      name: "pi-minimax",
      runner_key: "pi",
      auth_type: "api_key",
      api_provider: "minimax",
      model_env: "PAID_SMOKE_PI_MINIMAX_MODEL",
      default_model: "MiniMax-M2.7",
      label: "Pi with MiniMax Token Plan API key"
    ),
    "copilot-subscription" => Scenario.new(
      name: "copilot-subscription",
      runner_key: "copilot",
      auth_type: "subscription",
      label: "Copilot subscription"
    ),

    "claude-diag-baseline" => Scenario.new(
      name: "claude-diag-baseline",
      runner_key: "claude",
      auth_type: "subscription",
      label: "Claude diagnostic: bare prompt",
      diagnostic_prompt: "Reply with exactly OK.",
      diagnostic_timeout: 60,
      diagnostic_success_pattern: /\AOK[.!]?\z/i
    ),
    "claude-diag-tool-required" => Scenario.new(
      name: "claude-diag-tool-required",
      runner_key: "claude",
      auth_type: "subscription",
      label: "Claude diagnostic: forces a tool call",
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
    raise ScenarioUnavailableError, "Unknown runner smoke scenario #{name.inspect}"
  end

  def expand_name(name)
    return current_enabled_scenario_names if name == "current-enabled"

    PRESETS.fetch(name, [ name ])
  end

  def current_enabled_scenario_names
    DEFAULT_SCENARIO_NAMES | configured_scenario_names
  end

  def build_runner!(user:, scenario:)
    unless RunnerSupport.container_executable_runner_key?(scenario.runner_key)
      raise ScenarioUnavailableError,
        "#{scenario.label} is not runnable because #{scenario.runner_key} is not installed in the agent container"
    end

    if scenario.subscription?
      build_subscription_runner!(user: user, scenario: scenario)
    else
      build_direct_outbound_runner!(user: user, scenario: scenario)
    end
  end

  def build_subscription_runner!(user:, scenario:)
    user.runners.find_or_create_by!(runner_key: scenario.runner_key, auth_type: "subscription").tap do |runner|
      runner.update!(
        enabled_for_agent_runs: true,
        enabled_for_fallback: runner.enabled_for_fallback?
      )
    end
  end

  def build_direct_outbound_runner!(user:, scenario:)
    service_type = Runner::DIRECT_OUTBOUND_API_PROVIDERS.dig(scenario.api_provider, :service_type)
    if service_type.blank?
      raise ScenarioUnavailableError,
        "Unsupported #{scenario.runner_key} api provider #{scenario.api_provider.inspect} for #{scenario.label}"
    end

    dev_runner = development_runner_info_for(scenario)
    model_id = ENV[scenario.model_env].to_s.strip.presence ||
      scenario.default_model.presence ||
      dev_runner&.fetch("model", nil).to_s.presence
    if model_id.blank?
      raise ScenarioUnavailableError, "Set #{scenario.model_env} to run #{scenario.label}"
    end

    api_key = api_key_for_service_type(service_type, scenario: scenario, development_runner: dev_runner)
    if api_key.blank?
      raise ScenarioUnavailableError,
        "Set #{SERVICE_TYPE_ENV_VARS.fetch(service_type)} or create a matching provider/api key in the development DB to run #{scenario.label}"
    end

    provider_api_key = FactoryBot.create(
      :provider_api_key,
      user: user,
      api_service_type: service_type,
      api_key: api_key,
      name: "#{scenario.name} key"
    )

    runner = user.runners.api_key.find_or_initialize_by(
      runner_key: scenario.runner_key,
      provider_api_key: provider_api_key,
      name: scenario.label
    )
    runner.assign_attributes(
      enabled_for_agent_runs: true,
      enabled_for_fallback: false,
      config: {
        scenario.runner_key => {
          "api_provider" => scenario.api_provider,
          "model" => model_id
        }
      }
    )
    runner.save!
    runner
  end

  def api_key_for_service_type(service_type, scenario:, development_runner: nil)
    env_var = SERVICE_TYPE_ENV_VARS.fetch(service_type)
    ENV[env_var].to_s.strip.presence ||
      development_runner&.fetch("api_key", nil).to_s.strip.presence
  end

  def create_smoke_project!(user:)
    account = user.account
    github_token = FactoryBot.create(:github_token, account: account, created_by: user)
    FactoryBot.create(:project, account: account, created_by: user, github_token: github_token)
  end

  def development_runner_info_for(scenario)
    @development_runner_info_cache ||= {}
    return @development_runner_info_cache[scenario.name] if @development_runner_info_cache.key?(scenario.name)

    service_type = Runner::DIRECT_OUTBOUND_API_PROVIDERS.dig(scenario.api_provider, :service_type)
    desired_model = ENV[scenario.model_env].to_s.strip.presence || scenario.default_model
    payload = {
      runner_key: scenario.runner_key,
      auth_type: scenario.auth_type,
      api_provider: scenario.api_provider,
      service_type: service_type,
      desired_model: desired_model
    }
    runner_script = <<~'RUBY'
      require "json"

      scenario = JSON.parse(ENV.fetch("PAID_SMOKE_SCENARIO_JSON"))

      result = TenantContext.with_system_access do
        candidates = Runner.includes(:provider_api_key)
          .where(runner_key: scenario.fetch("runner_key"), auth_type: scenario.fetch("auth_type"))
          .select do |runner|
            next false unless runner.provider_api_key&.api_service_type == scenario.fetch("service_type")

            config = runner.config.is_a?(Hash) ? runner.config.fetch(scenario.fetch("runner_key"), {}) : {}
            config["api_provider"].to_s == scenario.fetch("api_provider")
          end

        if candidates.empty?
          { found: false }
        else
          desired = scenario["desired_model"].to_s
          exact = desired.present? ? candidates.select { |runner|
            config = runner.config.is_a?(Hash) ? runner.config.fetch(scenario.fetch("runner_key"), {}) : {}
            config["model"].to_s == desired
          } : []
          chosen = exact.one? ? exact.first : candidates.first
          config = chosen.config.is_a?(Hash) ? chosen.config.fetch(scenario.fetch("runner_key"), {}) : {}

          {
            found: true,
            runner_name: chosen.name,
            api_key_name: chosen.provider_api_key&.name,
            api_key: chosen.provider_api_key&.api_key,
            model: config["model"],
            candidate_names: candidates.map { |runner| runner.name.presence || "runner ##{runner.id}" }
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

    return @development_runner_info_cache[scenario.name] = nil unless status.success?

    parsed = JSON.parse(stdout.lines.last.to_s)
    return @development_runner_info_cache[scenario.name] = nil unless parsed["found"]

    if parsed["candidate_names"].is_a?(Array) && parsed["candidate_names"].uniq.many? && parsed["model"].to_s != desired_model.to_s
      raise ScenarioUnavailableError,
        "Multiple development DB runners match #{scenario.label}: #{parsed['candidate_names'].join(', ')}. Set #{scenario.model_env} to disambiguate."
    end

    @development_runner_info_cache[scenario.name] = parsed
  rescue JSON::ParseError
    nil
  end

  def configured_scenario_names
    payload = configured_runner_payload
    return [] unless payload.is_a?(Array)

    payload.filter_map do |config|
      scenario_for_configuration(config)
    end.uniq
  end

  def configured_runner_payload
    @configured_runner_payload ||= begin
      runner_script = <<~'RUBY'
        require "json"

        result = TenantContext.with_system_access do
          Runner.includes(:provider_api_key)
            .where(auth_type: %w[subscription api_key])
            .map do |runner|
              config = runner.config.is_a?(Hash) ? runner.config.fetch(runner.runner_key, {}) : {}
              {
                "runner_key" => runner.runner_key,
                "auth_type" => runner.auth_type,
                "service_type" => runner.provider_api_key&.api_service_type,
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
    rescue JSON::ParseError
      []
    end
  end

  def scenario_for_configuration(config)
    SCENARIOS.each_value.find do |scenario|
      next false unless scenario.runner_key == config["runner_key"].to_s
      next false unless scenario.auth_type == config["auth_type"].to_s
      next true if scenario.subscription?

      service_type = Runner::DIRECT_OUTBOUND_API_PROVIDERS.dig(scenario.api_provider, :service_type)
      service_type == config["service_type"].to_s &&
        scenario.api_provider == config["api_provider"].to_s
    end&.name
  end
end
