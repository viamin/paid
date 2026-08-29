# frozen_string_literal: true

require "base64"
require "set"
require "shellwords"

class Runner < ApplicationRecord
  has_logidze
  include Discard::Model
  include LegacyAttributeBridge
  include Runners::OpenRouterDataRouting

  OPENROUTER_FREE_MODEL_PROVIDER = "openrouter"
  DIRECT_OUTBOUND_FREE_POLICY_RUNNER_KEYS = %w[opencode kilocode pi omp].freeze
  # model_policy narrows how a direct-outbound runner picks its model:
  # "specific" pins a single configured model id (the default); "free"
  # drives selection from tier_model_ids via a tier picker. Free policy is
  # valid only when the runner resolves to the openrouter API provider.
  # @spec MODEL-POLICY-001 MODEL-POLICY-002 MODEL-POLICY-003
  MODEL_POLICIES = %w[specific free].freeze

  LEGACY_PROVIDER_ATTRIBUTE_BRIDGES = {
    "provider_key" => "runner_key"
  }.freeze
  AUTH_TYPES = %w[subscription api_key].freeze
  FALLBACK_ROLES = %w[standard rate_limit_fallback].freeze
  ROUTING_KEY_PREFIX = "runner:".freeze
  LEGACY_ROUTING_KEY_PREFIX = "provider:".freeze
  DEFAULT_WEIGHT = 1
  MAX_WEIGHT = 1000
  RUNNER_KEYS = RunnerSupport::APP_RUNNER_KEYS
  TIER_MODEL_VALUE_KEYS = %w[model_id provider_id].freeze
  # Default cutoffs for mapping a complexity score (1-10) to an LlmModel tier.
  # complexity <= low_max => "low", <= mid_max => "mid", else "high".
  DEFAULT_COMPLEXITY_THRESHOLDS = { "low_max" => 3, "mid_max" => 7 }.freeze
  COMPLEXITY_THRESHOLD_KEYS = %w[low_max mid_max].freeze
  # Per-provider defaults for the per-run input-token budget (#2511).
  # `min_input_tokens` is the input-token budget; `max_output_tokens` is the
  # output-token progress floor. A run is terminated as token_budget_exceeded
  # when it consumes >= min_input_tokens while producing < max_output_tokens.
  # These can be overridden per-runner via the no_progress_thresholds column,
  # and per-project via projects.token_budget_max_input_tokens.
  DEFAULT_NO_PROGRESS_THRESHOLDS = { "min_input_tokens" => 100_000, "max_output_tokens" => 100 }.freeze
  NO_PROGRESS_THRESHOLD_KEYS = %w[min_input_tokens max_output_tokens].freeze
  MAX_TIME_RESTRICTION_WINDOWS = 24
  # Upstream API providers supported by direct-outbound CLI tools (OpenCode,
  # KiloCode). Each entry maps a slug to its base URL and the ProviderApiKey
  # service type required for authentication.
  # Each entry carries an adapter hint so config generators can distinguish
  # OpenAI-compatible endpoints from providers with a native SDK (Anthropic).
  # Key contracts consumed by opencode_runner_runtime / opencode_qualified_model:
  #   - opencode_npm: drives BOTH SDK selection and base-URL routing. When it is
  #     "@ai-sdk/anthropic", the base URL goes to ANTHROPIC_BASE_URL and "npm" is
  #     injected into the provider config; otherwise the base URL goes to
  #     OPENAI_BASE_URL. Defaults to the openai-compatible adapter.
  #   - opencode_model_provider: names the provider-config block AND the model
  #     prefix (e.g. "minimax/<model>"). Required for any @ai-sdk/anthropic entry.
  #   - env_var: overrides the auto-derived "<SERVICE_TYPE>_API_KEY" name (MiniMax
  #     authenticates via ANTHROPIC_API_KEY despite its "minimax" service type).
  DIRECT_OUTBOUND_API_PROVIDERS = {
    "openrouter" => { label: "OpenRouter", base_url: "https://openrouter.ai/api/v1", service_type: "openrouter",
                      opencode_model_provider: "openrouter" },
    "anthropic" => { label: "Anthropic", base_url: "https://api.anthropic.com", service_type: "anthropic",
                     opencode_npm: "@ai-sdk/anthropic", kilocode_provider_id: "anthropic",
                     opencode_model_provider: "anthropic" },
    "openai" => { label: "OpenAI", base_url: "https://api.openai.com/v1", service_type: "openai",
                  kilocode_provider_id: "openai", opencode_model_provider: "openai" },
    "inception" => { label: "InceptionLabs", base_url: "https://api.inceptionlabs.ai/v1", service_type: "inception",
                     kilocode_provider_id: "inception", opencode_model_provider: "inception" },
    "deepseek" => { label: "DeepSeek", base_url: "https://api.deepseek.com/v1", service_type: "deepseek",
                    opencode_model_provider: "deepseek" },
    "mistral" => { label: "Mistral", base_url: "https://api.mistral.ai/v1", service_type: "mistral",
                   opencode_model_provider: "mistral" },
    "minimax" => { label: "MiniMax", base_url: "https://api.minimax.io/anthropic/v1", service_type: "minimax",
                   env_var: "ANTHROPIC_API_KEY", opencode_npm: "@ai-sdk/anthropic", kilocode_provider_id: "anthropic",
                   opencode_model_provider: "minimax" },
    "xai" => { label: "xAI", base_url: "https://api.x.ai/v1", service_type: "xai",
               opencode_model_provider: "xai" },
    "zai" => { label: "z.ai", base_url: "https://api.z.ai/api/paas/v4", service_type: "zai",
               opencode_model_provider: "zai", chat_max_tokens: 16_384 },
    # Both KiloCode and OpenCode ship a built-in "zai-coding-plan" provider
    # whose availability probe checks ZHIPU_API_KEY (not ZAI_CODING_API_KEY).
    # Override the auto-derived name so the key lands where the CLIs look.
    # opencode_model_provider matches the built-in provider id (hyphenated).
    # opencode_custom marks this as needing a declared model entry: opencode's
    # catalog tops out before glm-5.x, so opencode_runner_runtime extends the
    # built-in provider with the configured model instead of overriding it.
    "zai_coding" => { label: "z.ai (Coding Plan)", base_url: "https://api.z.ai/api/coding/paas/v4", service_type: "zai_coding",
                      env_var: "ZHIPU_API_KEY", kilocode_provider_id: "zai-coding-plan", opencode_model_provider: "zai-coding-plan",
                      opencode_custom: true, chat_max_tokens: 16_384 }
  }.freeze

  DIRECT_OUTBOUND_SERVICE_TYPES = DIRECT_OUTBOUND_API_PROVIDERS.values.map { |c| c[:service_type] }.to_set.freeze
  OPENAI_COMPATIBLE_DIRECT_OUTBOUND_API_PROVIDER_KEYS = DIRECT_OUTBOUND_API_PROVIDERS.filter_map do |provider_key, config|
    provider_key if (config[:opencode_npm] || "@ai-sdk/openai-compatible") == "@ai-sdk/openai-compatible"
  end.freeze

  OPENCODE_API_PROVIDER_KEYS = DIRECT_OUTBOUND_API_PROVIDERS.keys.freeze
  OPENCODE_DEFAULT_API_PROVIDER = "openrouter"

  KILOCODE_API_PROVIDER_KEYS = DIRECT_OUTBOUND_API_PROVIDERS.keys.freeze
  KILOCODE_DEFAULT_API_PROVIDER = "anthropic"
  # Paid-specific KiloCode addition: containerized runs need read access to the
  # installed agent-harness gem path. Upstream KiloCode defaults own the common
  # non-interactive allowlist (/tmp, /home/agent); Paid only layers this narrow
  # extra path on top.
  KILOCODE_EXTERNAL_DIRECTORY_PERMISSIONS = {
    "/usr/local/lib/ruby/gems/*/gems/agent-harness-*/**" => "allow"
  }.freeze
  MIN_PREFLIGHT_TIMEOUT_SECONDS = 1

  # Pi supports multiple upstream API-key providers selected via --provider.
  # Keep this list aligned to providers Paid can represent as ProviderApiKey
  # records and that Pi documents as built-in API-key auth targets.
  PI_API_PROVIDERS = {
    "anthropic" => { label: "Anthropic", service_type: "anthropic", env_var: "ANTHROPIC_API_KEY" },
    "openai" => { label: "OpenAI", service_type: "openai", env_var: "OPENAI_API_KEY" },
    "deepseek" => { label: "DeepSeek", service_type: "deepseek", env_var: "DEEPSEEK_API_KEY" },
    "google" => { label: "Google Gemini", service_type: "google", env_var: "GEMINI_API_KEY" },
    "mistral" => { label: "Mistral", service_type: "mistral", env_var: "MISTRAL_API_KEY" },
    "minimax" => { label: "MiniMax", service_type: "minimax", env_var: "ANTHROPIC_API_KEY" },
    "xai" => { label: "xAI", service_type: "xai", env_var: "XAI_API_KEY" },
    "zai" => { label: "z.ai", service_type: "zai", env_var: "ZAI_API_KEY" },
    "openrouter" => { label: "OpenRouter", service_type: "openrouter", env_var: "OPENROUTER_API_KEY" }
  }.freeze
  PI_API_PROVIDER_KEYS = PI_API_PROVIDERS.keys.freeze
  PI_DEFAULT_API_PROVIDER = "deepseek"
  OMP_API_PROVIDERS = PI_API_PROVIDERS
  OMP_API_PROVIDER_KEYS = OMP_API_PROVIDERS.keys.freeze
  OMP_DEFAULT_API_PROVIDER = PI_DEFAULT_API_PROVIDER

  belongs_to :user
  belongs_to :provider_api_key, optional: true
  belongs_to :integration_credential, optional: true

  has_many :chat_sessions, dependent: :nullify
  has_many :runner_credentials,
    ->(runner) { where(account_id: runner.user.account_id) },
    primary_key: :runner_key,
    foreign_key: :runner_key,
    inverse_of: false

  # Transient flag set by FreeModels::Rotation (and restore) when the
  # tier_model_ids change originates from the system rather than the user.
  # The before_save hook uses it to avoid clearing the rotation recovery
  # snapshot during a rotation write.
  attr_accessor :rotating_tier_models

  def rotating_tier_models?
    @rotating_tier_models == true
  end

  scope :kept_only, -> { kept }
  scope :for_agent_runs, -> { where(enabled_for_agent_runs: true) }
  scope :for_chat, -> { where(enabled_for_chat: true) }
  scope :for_fallback, -> { where(enabled_for_fallback: true) }
  scope :ordered, -> { order(:runner_key, :auth_type, :name, :id) }
  scope :subscription, -> { where(auth_type: "subscription") }
  scope :api_key, -> { where(auth_type: "api_key") }
  scope :rate_limit_fallback, -> { where(fallback_role: "rate_limit_fallback") }

  before_validation :normalize_agent_co_author_trailer
  before_validation :sync_provider_key_bridge
  before_validation :clear_stale_direct_outbound_tier_models
  before_save :ensure_manual_direct_outbound_catalog_entry
  before_save :sync_direct_outbound_tier_models
  before_save :clear_free_model_rotation_snapshot, unless: :rotating_tier_models?
  before_discard :prevent_destroying_last_agent_run_runner
  before_discard :prevent_destroying_default_runner
  before_discard :clear_provider_api_key_reference
  after_commit :invalidate_agent_run_runner_option_caches, if: :agent_run_runner_option_cache_invalidation_needed?
  after_commit :enqueue_parked_run_recovery, if: :became_available_for_agent_runs?

  validates :weight, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: MAX_WEIGHT }
  validates :monthly_token_budget,
    numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 2_147_483_647 },
    allow_nil: true
  validates :runner_key, presence: true, length: { maximum: 50 }
  validates :runner_key, inclusion: { in: ->(_) { supported_runner_keys }, message: "is not supported" },
    allow_blank: true, if: -> { new_record? || will_save_change_to_runner_key? }
  validates :auth_type, presence: true, inclusion: { in: AUTH_TYPES }
  validates :fallback_role, presence: true, inclusion: { in: FALLBACK_ROLES }
  validates :name, length: { maximum: 100 }
  validates :runner_key,
    uniqueness: {
      scope: [ :user_id, :auth_type ],
      conditions: -> { kept },
      message: "already has a subscription entry"
    },
    if: -> { subscription? }

  validate :must_keep_at_least_one_agent_run_runner
  validate :default_runner_must_remain_enabled_for_agent_runs
  validate :api_key_auth_requires_provider_api_key
  validate :subscription_auth_must_not_have_api_key
  validate :api_key_must_be_compatible
  validate :api_key_must_belong_to_same_account
  validate :integration_credential_must_be_active
  validate :subscription_must_have_standard_fallback_role
  validate :api_key_entry_must_be_unique
  validate :free_model_policy_runner_must_be_unique_per_credential
  validate :direct_outbound_model_policy_must_be_valid
  validate :opencode_api_key_config_must_be_valid
  validate :kilocode_api_key_config_must_be_valid
  validate :pi_api_key_config_must_be_valid
  validate :omp_api_key_config_must_be_valid
  validate :direct_outbound_config_models_must_exist_in_catalog
  validate :tier_model_ids_must_be_valid
  validate :tier_model_ids_must_be_runner_compatible
  validate :tier_models_must_be_valid
  validate :tier_models_must_be_runner_compatible
  validate :complexity_thresholds_must_be_valid
  validate :no_progress_thresholds_must_be_valid
  validate :time_restrictions_must_be_valid
  validate :agent_co_author_trailer_is_single_line

  before_destroy :prevent_destroying_last_agent_run_runner
  before_destroy :prevent_destroying_default_runner

  def subscription?
    auth_type == "subscription"
  end

  def api_key?
    auth_type == "api_key"
  end

  def rate_limit_fallback?
    fallback_role == "rate_limit_fallback"
  end

  def effective_api_secret
    return provider_api_key&.api_key.to_s.presence if provider_api_key.present?
    return unless active_integration_credential?

    integration_credential.api_secret
  end

  def active_integration_credential?
    integration_credential&.category == "llm_provider" && integration_credential&.active?
  end

  def proxy_route_compatible?(provider)
    required_api_service_type == provider.to_s
  end

  # @spec MODEL-POLICY-006
  def display_name
    return name if name.present?

    if direct_outbound_free_policy?
      provider_label = direct_outbound_api_label || "OpenRouter"
      label = "#{direct_outbound_runner_label} Free (#{provider_label})"
      label += " (API Key)" if api_key?
      return label
    end

    label = self.class.display_name_for(runner_key)
    model_id = case runner_key
    when "opencode" then opencode_model_id
    when "kilocode" then kilocode_model_id
    when "pi" then pi_model_id
    when "omp" then omp_model_id
    end
    label += " #{model_id}" if model_id.present?
    label += " (API Key)" if api_key?
    label
  end

  def update_columns(attributes)
    super(self.class.synchronize_bridge_attributes(attributes, LEGACY_PROVIDER_ATTRIBUTE_BRIDGES))
  end

  # Returns a merged hash of complexity thresholds (stored values overlaid on
  # defaults) so callers can read a concrete mapping without re-checking for
  # missing keys every time. Integers are coerced so JSONB round-trips (which
  # may preserve Rails' Integer/Float or return strings) don't leak into the
  # tier-mapping logic.
  def effective_complexity_thresholds
    stored = complexity_thresholds.is_a?(Hash) ? complexity_thresholds : {}
    DEFAULT_COMPLEXITY_THRESHOLDS.merge(stored.slice(*COMPLEXITY_THRESHOLD_KEYS))
      .transform_values { |v| Integer(v, exception: false) || v }
  end

  # Returns a merged hash of no-progress thresholds (stored values overlaid on
  # defaults) so callers can read concrete token limits without re-checking for
  # missing keys. Integers are coerced so JSONB round-trips don't leak strings.
  def effective_no_progress_thresholds
    stored = no_progress_thresholds.is_a?(Hash) ? no_progress_thresholds : {}
    DEFAULT_NO_PROGRESS_THRESHOLDS.merge(stored.slice(*NO_PROGRESS_THRESHOLD_KEYS))
      .transform_values { |v| Integer(v, exception: false) || v }
  end

  # --- Time-window restrictions (@spec RUNNER-SCHED-001..010) ---

  def time_window_check(now: Time.current)
    Runners::TimeWindowCheck.new(self[:time_restrictions], now: now)
  end

  def time_restrictions_configured?
    time_window_check.restrictions_enabled?
  end

  def blocked_by_time_window?(now: Time.current)
    time_window_check(now: now).blocked_at?
  end

  def execution_enabled_for_agent_runs?(disabled_runner_ids: nil)
    return !disabled_runner_ids.include?(id) if disabled_runner_ids

    !ExecutionControl.enabled.for_runner_scope(id).exists?
  end

  def deprioritized_by_time_window?(now: Time.current)
    time_window_check(now: now).deprioritized_at?
  end

  def restricted_by_time_window?(now: Time.current)
    time_window_check(now: now).restricted_at?
  end

  def next_time_window_available_at(now: Time.current)
    time_window_check(now: now).next_available_at
  end

  def routing_key
    persisted? ? "#{ROUTING_KEY_PREFIX}#{id}" : runner_key.to_s
  end

  def matches_identifier?(identifier)
    id_str = identifier.to_s
    return true if id_str == routing_key || id_str == legacy_routing_key || id_str == runner_key.to_s

    # Also match agent_type identifiers (e.g. "claude_code") that map
    # to this runner's key (e.g. "claude") so that legacy final_runner
    # values are handled correctly.
    normalized = RunnerSupport.runner_key_for_agent_type(id_str)
    normalized != id_str && normalized == runner_key.to_s
  end

  def state_key
    subscription? ? runner_key.to_s : routing_key
  end

  def monthly_budget_configured?
    monthly_token_budget.to_i.positive?
  end

  def quota_check_runtime
    return subscription_quota_runtime if subscription?

    nil
  end

  def tier_models
    normalize_tier_models(self[:tier_models])
  end

  def tier_models=(value)
    self[:tier_models] = normalize_tier_models(value)
  end

  def supports_tier?(tier)
    tier_models[tier.to_s].present?
  end

  def legacy_routing_key
    persisted? ? "#{LEGACY_ROUTING_KEY_PREFIX}#{id}" : runner_key.to_s
  end

  def opencode_config
    config.is_a?(Hash) ? config.fetch("opencode", {}) : {}
  end

  def subscription_quota_runtime
    unset_vars = RunnerSupport.subscription_auth_unset_vars_for(runner_key)
    return nil if unset_vars.empty?

    unset_vars = unset_vars.dup
    unset_vars.delete("COPILOT_GITHUB_TOKEN") if runner_key == "copilot"
    AgentHarness::ProviderRuntime.new(unset_env: unset_vars)
  end
  def opencode_api_provider
    return nil unless runner_key == "opencode"

    derived_api_provider_for(provider_api_key, legacy_value: opencode_config["api_provider"], default: OPENCODE_DEFAULT_API_PROVIDER)
  end

  def opencode_model_id
    return nil unless runner_key == "opencode"

    opencode_config["model"].to_s.presence
  end

  # @spec MODEL-POLICY-001
  def opencode_model_policy
    return nil unless runner_key == "opencode"

    direct_outbound_model_policy
  end

  # True for a direct-outbound runner configured with model_policy "free".
  # Must resolve tier_model_ids exclusively to free LlmModel rows, curated by
  # sync_direct_outbound_tier_models.
  # @spec MODEL-POLICY-004
  def free_model_policy?
    direct_outbound_free_policy?
  end

  def opencode_preflight_timeout_seconds
    return nil unless runner_key == "opencode"

    Integer(opencode_config["preflight_timeout_seconds"], exception: false)
  end

  # Returns a runner-specific preflight timeout override when configured,
  # covering all direct-outbound runner types.  Returns nil when no override
  # is set, letting the caller fall back to the default direct-outbound budget.
  def runner_preflight_timeout_seconds
    case runner_key
    when "kilocode" then kilocode_preflight_timeout_seconds
    when "opencode" then opencode_preflight_timeout_seconds
    end
  end

  def kilocode_config
    config.is_a?(Hash) ? config.fetch("kilocode", {}) : {}
  end

  def kilocode_api_provider
    return nil unless runner_key == "kilocode"

    derived_api_provider_for(provider_api_key, legacy_value: kilocode_config["api_provider"], default: KILOCODE_DEFAULT_API_PROVIDER)
  end

  def kilocode_model_id
    return nil unless runner_key == "kilocode"

    kilocode_config["model"].to_s.presence
  end

  def kilocode_preflight_timeout_seconds
    return nil unless runner_key == "kilocode"

    Integer(kilocode_config["preflight_timeout_seconds"], exception: false)
  end

  def kilocode_required_api_service_type
    return nil unless runner_key == "kilocode"

    DIRECT_OUTBOUND_API_PROVIDERS.dig(kilocode_api_provider, :service_type)
  end

  def pi_config
    config.is_a?(Hash) ? config.fetch("pi", {}) : {}
  end

  def pi_api_provider
    return nil unless runner_key == "pi"

    derived_api_provider_for(provider_api_key, legacy_value: pi_config["api_provider"], default: PI_DEFAULT_API_PROVIDER)
  end

  def pi_model_id
    return nil unless runner_key == "pi"

    pi_config["model"].to_s.presence
  end

  def pi_required_api_service_type
    return nil unless runner_key == "pi"

    PI_API_PROVIDERS.dig(pi_api_provider, :service_type)
  end

  def omp_config
    config.is_a?(Hash) ? config.fetch("omp", {}) : {}
  end

  def omp_api_provider
    return nil unless runner_key == "omp"

    derived_api_provider_for(provider_api_key, legacy_value: omp_config["api_provider"], default: OMP_DEFAULT_API_PROVIDER)
  end

  def omp_model_id
    return nil unless runner_key == "omp"

    omp_config["model"].to_s.presence
  end

  def omp_required_api_service_type
    return nil unless runner_key == "omp"

    OMP_API_PROVIDERS.dig(omp_api_provider, :service_type)
  end

  def requires_direct_outbound?
    opencode_direct_outbound? || kilocode_direct_outbound? || pi_direct_outbound? || omp_direct_outbound?
  end

  def opencode_required_api_service_type
    return nil unless runner_key == "opencode"

    DIRECT_OUTBOUND_API_PROVIDERS.dig(opencode_api_provider, :service_type)
  end

  def kilocode_config_json
    preparation = kilocode_harness_provider.plan_execution(
      prompt: "ping",
      provider_runtime: kilocode_runner_runtime
    ).fetch(:preparation)

    preparation&.file_writes&.find { |file| file.path == "~/.config/kilocode/kilo.json" }&.content ||
      raise("agent-harness did not generate a KiloCode config file")
  end

  def kilocode_qualified_model(provider_id, model_id)
    model_id.start_with?("#{provider_id}/") ? model_id : "#{provider_id}/#{model_id}"
  end

  # Qualifies a model id with the runner's opencode provider prefix
  # (e.g. "minimax/MiniMax-M3"). Defaults to the runner's configured model but
  # accepts an explicit model_id so models resolved outside the runtime builder
  # (tier resolution, escalation) get the same treatment. Idempotent: a value
  # already prefixed with this provider is returned unchanged.
  def opencode_qualified_model(model_id = opencode_model_id)
    return if model_id.blank?

    api_config = DIRECT_OUTBOUND_API_PROVIDERS.fetch(opencode_api_provider, DIRECT_OUTBOUND_API_PROVIDERS["openrouter"])
    provider_id = api_config[:opencode_model_provider]
    return model_id if provider_id.blank? || model_id.start_with?("#{provider_id}/")

    "#{provider_id}/#{model_id}"
  end

  # Re-applies the runner's direct-outbound provider qualification to a model id
  # resolved outside the runtime builder. Tier resolution returns the bare
  # tier_model_ids value, which would otherwise overwrite configured_runtime's
  # qualified model and ship an unqualified id to opencode. opencode parses a
  # bare id as a provider with an empty model (e.g. "MiniMax-M3" ->
  # provider="MiniMax-M3", model="") and raises ProviderModelNotFoundError, so a
  # bare id needs the runner's "<provider>/<model>" form.
  #
  # A model id that already carries a "/" is left untouched: OpenRouter-routed
  # ids are "<vendor>/<model>" slugs (e.g. "moonshotai/kimi-k2-0905") that
  # opencode addresses directly. No-op for runners that do not
  # provider-qualify their models.
  def qualified_model_for(model_id)
    return model_id if model_id.blank? || model_id.include?("/")
    return opencode_qualified_model(model_id) if runner_key == "opencode"

    model_id
  end

  def kilocode_api_key_env_var
    api_config = DIRECT_OUTBOUND_API_PROVIDERS[kilocode_api_provider.to_s]
    return "OPENAI_API_KEY" if api_config.blank?

    api_config[:env_var].presence || "#{api_config[:service_type].upcase.tr('-', '_')}_API_KEY"
  end

  def kilocode_runtime_env
    api_key = effective_api_secret.to_s
    return {} if api_key.blank?

    { kilocode_api_key_env_var => api_key }
  end

  def kilocode_runner_runtime(project: nil, model_id: kilocode_model_id)
    return free_model_policy_runner_runtime(project: project, model_id: model_id) if kilocode_free_model_policy_runtime?

    raise ArgumentError, "Missing KiloCode model id for runner #{id || runner_key}" if model_id.blank?

    api_config = DIRECT_OUTBOUND_API_PROVIDERS.fetch(kilocode_api_provider, DIRECT_OUTBOUND_API_PROVIDERS["anthropic"])
    kilocode_provider_id = api_config[:kilocode_provider_id] || "openai-compatible"
    options = { "apiKey" => "{env:#{kilocode_api_key_env_var}}" }
    base_url = api_config[:base_url]
    default_openai_url = DIRECT_OUTBOUND_API_PROVIDERS.dig("openai", :base_url)
    options["baseURL"] = base_url if base_url.present? && base_url != default_openai_url

    AgentHarness::ProviderRuntime.new(
      model: kilocode_qualified_model(kilocode_provider_id, model_id),
      env: kilocode_runtime_env,
      metadata: {
        config: {
          "provider" => {
            kilocode_provider_id => {
              "options" => options,
              "models" => {
                model_id => {
                  "name" => model_id,
                  "id" => model_id,
                  "tool_call" => true
                }
              }
            }
          },
          "permission" => {
            "external_directory" => KILOCODE_EXTERNAL_DIRECTORY_PERMISSIONS
          }
        }
      }
    )
  end

  def direct_outbound_exec_env
    if kilocode_direct_outbound?
      kilocode_runtime_env.merge("PAID_KILOCODE_CONFIG_B64" => Base64.strict_encode64(kilocode_config_json))
    else
      {}
    end
  end

  def direct_outbound_exec_command(command_prefix:, prompt:)
    return command_prefix + [ prompt ] unless kilocode_direct_outbound?

    command = "#{command_prefix.shelljoin} \"$1\""

    script = <<~SH.squish
      mkdir -p /home/agent/.config/kilocode &&
      printf '%s' "$PAID_KILOCODE_CONFIG_B64" | base64 -d > /home/agent/.config/kilocode/kilo.json &&
      #{command}
    SH

    [ "sh", "-lc", script, "--", prompt ]
  end

  def agent_harness_runner_runtime(project: nil)
    return free_model_policy_runner_runtime(project: project, model_id: free_policy_default_model_id) if direct_outbound_free_policy?
    return opencode_runner_runtime(project: project) if opencode_direct_outbound?
    return pi_runner_runtime if pi_agent_harness_runtime?
    return omp_runner_runtime if omp_agent_harness_runtime?

    nil
  end

  def agent_harness_runtime?
    direct_outbound_free_policy? || opencode_agent_harness_runtime? || copilot_agent_harness_runtime? || pi_agent_harness_runtime? || omp_agent_harness_runtime?
  end

  def opencode_agent_harness_runtime?
    runner_key == "opencode" && requires_direct_outbound?
  end

  def copilot_agent_harness_runtime?
    runner_key == "copilot"
  end

  def pi_agent_harness_runtime?
    runner_key == "pi" &&
      api_key? &&
      PI_API_PROVIDER_KEYS.include?(pi_api_provider)
  end

  def omp_agent_harness_runtime?
    runner_key == "omp" &&
      api_key? &&
      OMP_API_PROVIDER_KEYS.include?(omp_api_provider)
  end

  def direct_outbound_model_id
    case runner_key
    when "kilocode" then kilocode_model_id
    when "opencode" then opencode_model_id
    when "pi" then pi_model_id
    when "omp" then omp_model_id
    end
  end

  def direct_outbound_llm_model_provider
    case runner_key
    when "kilocode" then kilocode_required_api_service_type
    when "opencode" then opencode_required_api_service_type
    when "pi" then pi_required_api_service_type
    when "omp" then omp_required_api_service_type
    end
  end

  def ensure_direct_outbound_llm_model!
    model_id = direct_outbound_model_id
    raise ArgumentError, "No direct-outbound model configured" if model_id.blank?

    model = find_direct_outbound_catalog_model(model_id)
    raise ArgumentError, "Direct-outbound model #{model_id.inspect} is not present in the catalog" if model.blank?

    # Reactivate if an existing row was returned inactive — model selection
    # resolves via LlmModel.active so an inactive record would silently
    # fall back to the global pool.
    model.update!(active: true) unless model.active?
    model
  end

  # Returns the runner key that must always exist and remain enabled for
  # agent runs. Returns the first container-executable runner key in
  # supported order, with no hardcoded preference for any specific runner.
  # Returns nil when no container-executable runners are available, so
  # callers can surface a user-facing error instead of a 500.
  def self.default_runner_key
    RunnerSupport.container_executable_runner_keys.first
  end

  def self.ensure_default_for(user)
    key = default_runner_key
    return unless key

    relation = user.runners.kept_only
    deadlock_retries = 0

    begin
      relation.find_or_create_by!(runner_key: key, auth_type: "subscription")
    rescue ActiveRecord::Deadlocked
      deadlock_retries += 1
      raise if deadlock_retries > 3

      sleep(0.01 * deadlock_retries)
      retry
    rescue ActiveRecord::RecordNotUnique => e
      if primary_key_conflict?(e)
        connection.reset_pk_sequence!(table_name)
        retry
      end

      relation.find_by!(runner_key: key, auth_type: "subscription")
    end
  end

  def self.first_enabled_for_owner(owner)
    return unless owner

    executable_keys = RunnerSupport.container_executable_runner_keys
    owner.runners.kept_only.for_agent_runs.where(runner_key: executable_keys).ordered.first
  end

  def self.first_configured_chat_enabled_for_owner(owner)
    return unless owner

    executable_keys = RunnerSupport.container_executable_runner_keys
    owner.runners.kept_only.for_chat.api_key
      .includes(:provider_api_key, :integration_credential)
      .where(runner_key: executable_keys)
      .ordered
      .find do |runner|
      runner.effective_api_secret.present?
    end
  end

  def self.display_name_for(runner_key)
    return "Unknown" if runner_key.blank?

    provider = AgentHarness.provider(RunnerSupport.harness_runner_key_for(runner_key).to_sym)

    if provider.respond_to?(:display_name)
      provider.display_name
    else
      runner_key.to_s.titleize
    end
  rescue AgentHarness::ConfigurationError
    runner_key.to_s.titleize
  end

  def self.display_name(runner_key)
    display_name_for(runner_key)
  end

  def self.supported_runner_keys
    RunnerSupport.supported_runner_keys
  end

  def self.supported_runner_key?(runner_key)
    RunnerSupport.supported_runner_key?(runner_key)
  end

  def self.addable_runner_keys
    RunnerSupport.addable_runner_keys
  end

  def self.addable_runner_key?(runner_key)
    RunnerSupport.addable_runner_key?(runner_key)
  end

  def self.harness_runner_key_for(runner_key)
    RunnerSupport.harness_runner_key_for(runner_key)
  end

  def self.runner_key_for_agent_type(agent_type)
    RunnerSupport.runner_key_for_agent_type(agent_type)
  end

  def self.agent_type_for(runner_key)
    RunnerSupport.agent_type_for(runner_key)
  end

  def self.primary_key_conflict?(error)
    [ error.message, error.cause&.message ].compact.any? { |message| message.include?("#{table_name}_pkey") }
  end
  private_class_method :primary_key_conflict?

  def self.api_service_type_for(runner_key)
    RunnerSupport.api_service_type_for(runner_key)
  end

  def self.api_service_type_to_provider_key(service_type)
    normalized = service_type.to_s

    DIRECT_OUTBOUND_API_PROVIDERS.each do |provider_key, config|
      return provider_key if config[:service_type] == normalized
    end

    PI_API_PROVIDERS.each do |provider_key, config|
      return provider_key if config[:service_type] == normalized
    end

    nil
  end

  def self.routing_key?(identifier)
    routing_key_prefix_for(identifier).present?
  end

  def self.id_from_routing_key(identifier)
    prefix = routing_key_prefix_for(identifier)
    return unless prefix

    id_str = identifier.to_s.delete_prefix(prefix)
    id = Integer(id_str, exception: false)
    return unless id&.positive?

    id
  end

  def self.for_identifier(user, identifier, include_discarded: false)
    return nil unless user
    return nil if identifier.blank?

    if routing_key?(identifier)
      relation = include_discarded ? with_discarded : kept_only
      relation.where(user: user).find_by(id: id_from_routing_key(identifier))
    else
      if include_discarded
        preferred_identifier_match(kept_only.where(user: user, runner_key: identifier).ordered) ||
          preferred_identifier_match(with_discarded.where(user: user, runner_key: identifier).discarded.ordered)
      else
        preferred_identifier_match(kept_only.where(user: user, runner_key: identifier).ordered)
      end
    end
  end

  def self.filter_option_for_identifier(identifier, account_id:)
    return if identifier.blank?

    if routing_key?(identifier)
      runner_id = id_from_routing_key(identifier)
      return unless runner_id

      runner = with_discarded.joins(:user).find_by(id: runner_id, users: { account_id: account_id })
      return unless runner

      return {
        label: runner.display_name,
        value: identifier
      }
    end

    normalized_identifier = RunnerSupport.runner_key_for_agent_type(identifier)

    {
      label: display_name_for(normalized_identifier),
      value: normalized_identifier
    }
  end

  # Updates the enabled_for_fallback flag on each of the user's runners
  # based on the given set of enabled runner identifiers.
  def self.update_fallback_flags(user, enabled_keys)
    user.runners.kept_only.transaction do
      user.runners.kept_only.find_each do |runner|
        new_value = enabled_keys.any? { |identifier| runner.matches_identifier?(identifier) }
        next if runner.enabled_for_fallback? == new_value

        unless runner.update(enabled_for_fallback: new_value)
          raise ActiveRecord::Rollback
        end
      end
    end
  end

  private

  # Registers the user-entered direct-outbound model id in the LlmModel catalog
  # with catalog_source: "manual" so downstream selection has a row to resolve
  # (#2669). Runs before sync_direct_outbound_tier_models so the tier-mapping
  # callback finds the row. A row whose provider differs from the runner's
  # expected service_type is left untouched — direct_outbound_config_models_must_exist_in_catalog
  # rejects the save in that case before this hook runs.
  def ensure_manual_direct_outbound_catalog_entry
    return unless direct_outbound_capable_runner?
    return unless will_save_change_to_config?

    bare_model_id = manual_direct_outbound_bare_model_id
    return if bare_model_id.blank?

    expected_provider = direct_outbound_llm_model_provider
    return if expected_provider.blank?

    LlmModel.upsert_manual_catalog_entry(model_id: bare_model_id, provider: expected_provider)
  end

  # Returns the bare model id (no provider prefix) used as the catalog key
  # when materializing a manual catalog entry. Prefers the bare form so
  # future lookups using either the qualified or bare model id resolve to
  # the same row, matching how Models::SeedKnownModels stores entries.
  def manual_direct_outbound_bare_model_id
    raw_id = direct_outbound_model_id.to_s
    return if raw_id.blank?

    provider_prefix = direct_outbound_catalog_provider_prefix
    return raw_id.delete_prefix("#{provider_prefix}/") if provider_prefix.present? && raw_id.start_with?("#{provider_prefix}/")

    raw_id
  end

  # @spec MODEL-POLICY-005
  def sync_direct_outbound_tier_models
    if free_model_policy?
      return unless tier_model_ids.blank?

      # @spec FREE-MODEL-RUNNER-002
      default_tier_model_ids = FreeModels::DefaultTierModels.call
      self.tier_model_ids = default_tier_model_ids if default_tier_model_ids.present?
      return
    end

    return unless requires_direct_outbound?
    return unless direct_outbound_model_id.present?
    return unless will_save_change_to_config? || tier_model_ids.blank?

    model = ensure_direct_outbound_llm_model!
    self.tier_model_ids = LlmModel::TIERS.each_with_object({}) { |t, h| h[t] = model.model_id }
  end

  # @spec MODEL-POLICY-005
  def clear_stale_direct_outbound_tier_models
    return unless tier_model_ids.present?
    return if free_model_policy?
    return unless direct_outbound_capable_runner?
    return if requires_direct_outbound? && direct_outbound_model_id.present?

    self.tier_model_ids = {}
  end

  # When the user explicitly changes tier_model_ids on a free-policy runner,
  # drop any free-model rotation recovery snapshot so a later successful run
  # does not revert their edit back to the pre-rotation mapping. System
  # rotations set +rotating_tier_models+ to skip this. The snapshot lives on
  # the RunnerState row keyed by the runner's routing-key state_key (matching
  # FreeModels::Rotation), so the lookup uses the same key that wrote it.
  # Only relevant when editing an existing runner — creating a runner must
  # not wipe a pre-existing recovery snapshot.
  # @spec MODEL-POLICY-012
  def clear_free_model_rotation_snapshot
    return if new_record?
    return unless free_model_policy?
    return unless required_api_service_type == OPENROUTER_FREE_MODEL_PROVIDER
    return unless will_save_change_to_tier_model_ids?
    return unless user

    state = user.runner_states.find_by(runner_name: state_key)
    state&.clear_preferred_tier_model_ids!
  end

  def direct_outbound_capable_runner?
    %w[kilocode opencode pi omp].include?(runner_key)
  end

  def direct_outbound_api_key_env_var(api_provider)
    api_config = DIRECT_OUTBOUND_API_PROVIDERS[api_provider.to_s]
    return "OPENAI_API_KEY" if api_config.blank?

    api_config[:env_var].presence || "#{api_config[:service_type].upcase.tr('-', '_')}_API_KEY"
  end

  def normalize_agent_co_author_trailer
    stripped = agent_co_author_trailer.to_s.strip
    self.agent_co_author_trailer = stripped.present? ? stripped : nil
  end

  def sync_provider_key_bridge
    if will_save_change_to_runner_key?
      self[:provider_key] = runner_key
    elsif will_save_change_to_provider_key?
      self[:runner_key] = self[:provider_key]
    elsif self[:runner_key].blank? && self[:provider_key].present?
      self[:runner_key] = self[:provider_key]
    elsif self[:provider_key].blank? && self[:runner_key].present?
      self[:provider_key] = self[:runner_key]
    end
  end

  def agent_co_author_trailer_is_single_line
    return if agent_co_author_trailer.blank?
    return unless agent_co_author_trailer.match?(/[\r\n]/)

    errors.add(:agent_co_author_trailer, "must be a single line (no newlines)")
  end

  def must_keep_at_least_one_agent_run_runner
    return unless user
    return unless will_save_change_to_enabled_for_agent_runs?(from: true, to: false)
    return if user.runners.kept_only.where.not(id: id).for_agent_runs.exists?

    errors.add(:enabled_for_agent_runs, "must keep at least one runner enabled for agent runs")
  end

  def prevent_destroying_last_agent_run_runner
    return if destroyed_by_association.present?
    return unless enabled_for_agent_runs?
    return if user.runners.kept_only.where.not(id: id).for_agent_runs.exists?

    errors.add(:base, "Cannot delete the last runner enabled for agent runs")
    throw(:abort)
  end

  def default_runner_must_remain_enabled_for_agent_runs
    default_key = self.class.default_runner_key
    return unless default_key
    return unless runner_key == default_key && subscription?
    return unless will_save_change_to_enabled_for_agent_runs?(to: false)

    errors.add(:enabled_for_agent_runs,
      "#{Runner.display_name(default_key)} must remain enabled for agent runs")
  end

  def prevent_destroying_default_runner
    default_key = self.class.default_runner_key
    return if destroyed_by_association.present?
    return unless default_key
    return unless runner_key == default_key && subscription?

    errors.add(:base, "Cannot delete the #{Runner.display_name(default_key)} runner")
    throw(:abort)
  end

  def invalidate_agent_run_runner_option_caches
    return unless user

    AgentRun.invalidate_runner_options_cache(account_id: user.account_id)
  end

  def clear_provider_api_key_reference
    self.provider_api_key = nil if provider_api_key_id.present?
  end

  def agent_run_runner_option_cache_invalidation_needed?
    previous_changes.key?("id") ||
      previous_changes.key?("discarded_at") ||
      previous_changes.key?("name") ||
      previous_changes.key?("runner_key") ||
      previous_changes.key?("auth_type") ||
      display_name_config_changed?
  end

  # True when this runner just became usable for agent runs — created,
  # re-enabled, or undiscarded. Used to wake parked `rate_limited` runs so they
  # re-dispatch onto the newly-available capacity instead of waiting out the
  # original runner's full rate-limit window.
  def became_available_for_agent_runs?
    # The enabled_for_agent_runs? guard means any change to that column was a
    # re-enable (false -> true); a disable returns false above.
    return false unless user_id.present? && enabled_for_agent_runs?

    previous_changes.key?("id") ||
      previous_changes.key?("enabled_for_agent_runs") ||
      (previous_changes.key?("discarded_at") && discarded_at.nil?)
  end

  def enqueue_parked_run_recovery
    return unless Runners::RecoverParkedRunsJob.parked_runs_for(user).exists?

    Runners::RecoverParkedRunsJob.perform_later(user_id)
  end

  def display_name_config_changed?
    previous_config, current_config = previous_changes["config"]
    return false unless previous_changes.key?("config")

    display_name_config_value(previous_config) != display_name_config_value(current_config)
  end

  def display_name_config_value(config_value)
    config = config_value.is_a?(Hash) ? config_value : {}

    case runner_key
    when "opencode"
      [ config.dig("opencode", "model"), config.dig("opencode", "model_policy") ]
    when "kilocode"
      [ config.dig("kilocode", "model"), config.dig("kilocode", "model_policy") ]
    when "pi"
      [ config.dig("pi", "model"), config.dig("pi", "model_policy") ]
    when "omp"
      [ config.dig("omp", "model"), config.dig("omp", "model_policy") ]
    end
  end

  def self.preferred_identifier_match(matching_runners)
    matching_runners.subscription.first || matching_runners.first
  end
  private_class_method :preferred_identifier_match

  def self.routing_key_prefix_for(identifier)
    value = identifier.to_s
    return ROUTING_KEY_PREFIX if value.start_with?(ROUTING_KEY_PREFIX)
    return LEGACY_ROUTING_KEY_PREFIX if value.start_with?(LEGACY_ROUTING_KEY_PREFIX)

    nil
  end
  private_class_method :routing_key_prefix_for

  def api_key_auth_requires_provider_api_key
    return unless api_key?
    return if provider_api_key.present? || integration_credential.present?

    errors.add(:provider_api_key, "is required for API key authentication")
  end

  def subscription_auth_must_not_have_api_key
    return unless subscription?
    return if provider_api_key_id.blank? && integration_credential_id.blank?

    credential_error_attribute = provider_api_key_id.present? ? :provider_api_key : :integration_credential
    errors.add(credential_error_attribute, "must not be set for subscription authentication")
  end

  def api_key_must_be_compatible
    return unless api_key?
    return if provider_api_key_id.blank? && integration_credential_id.blank?

    required_service = required_api_service_type

    if required_service.nil?
      credential_error_attribute = provider_api_key.present? ? :provider_api_key : :integration_credential
      errors.add(credential_error_attribute, "is not supported for this runner; use subscription authentication instead")
      return
    end

    if provider_api_key.present?
      return if provider_api_key.api_service_type == required_service

      errors.add(:provider_api_key, "must be an API key for #{RunnerSupport.api_service_type_label(required_service)}")
      return
    end

    return if integration_credential.present? &&
      integration_credential.category == "llm_provider" &&
      integration_credential.service_key == runner_key

    errors.add(:integration_credential, "must match this runner")
  end

  def api_key_must_belong_to_same_account
    return unless api_key?
    if provider_api_key.present?
      return if provider_api_key.user&.account_id == user&.account_id

      errors.add(:provider_api_key, "must belong to the same account")
      return
    end

    return unless integration_credential.present?
    return if integration_credential.account_id == user&.account_id

    errors.add(:integration_credential, "must belong to the same account")
  end

  def subscription_must_have_standard_fallback_role
    return unless subscription?
    return if fallback_role == "standard"

    errors.add(:fallback_role, "must be standard for subscription runners")
  end

  def api_key_entry_must_be_unique
    return unless api_key?
    return unless user

    normalized_name = name.to_s
    duplicate = user.runners.kept_only.api_key.where(
      runner_key: runner_key,
      provider_api_key_id: provider_api_key_id,
      integration_credential_id: integration_credential_id
    ).where.not(id: id).where("COALESCE(name, '') = ?", normalized_name).exists?
    return unless duplicate

    errors.add(:runner_key, "already has an entry with this API key")
  end

  # Enforces "one free-policy runner per user per OpenRouter credential": a
  # user may hold a free-policy runner (e.g. opencode with model_policy
  # "free") per distinct provider_api_key/integration_credential, but not two
  # pointed at the same credential — they would both draw on the same
  # free-tier quota. This is deliberately broader than
  # api_key_entry_must_be_unique's per-runner_key scope.
  # @spec MODEL-POLICY-007
  def free_model_policy_runner_must_be_unique_per_credential
    return unless free_model_policy?
    return unless api_key?
    return unless user
    return if provider_api_key_id.blank? && integration_credential_id.blank?

    duplicate = user.runners.kept_only.api_key.where.not(id: id).where(
      provider_api_key_id: provider_api_key_id,
      integration_credential_id: integration_credential_id
    ).any?(&:free_model_policy?)
    return unless duplicate

    errors.add(:runner_key, "already has a free-model runner for this OpenRouter credential")
  end

  def integration_credential_must_be_active
    return unless api_key?
    return unless integration_credential.present?
    return if integration_credential.active?

    errors.add(:integration_credential, "must be active")
  end

  # Runs for every direct-outbound free-policy-capable runner regardless of
  # auth type: model_policy determines whether the runner is free_model_policy?
  # (which feeds validators and dispatch logic for subscription and api_key
  # rows alike), so a crafted value must fail loudly instead of silently
  # passing when auth_type isn't api_key.
  # @spec MODEL-POLICY-001 MODEL-POLICY-002 MODEL-POLICY-003
  def direct_outbound_model_policy_must_be_valid
    return unless direct_outbound_free_policy_supported_runner?

    unless MODEL_POLICIES.include?(direct_outbound_model_policy)
      errors.add(:config, "must include a supported #{direct_outbound_runner_label} model policy")
      return
    end

    return unless direct_outbound_free_policy?

    errors.add(:auth_type, "must be API key for the free model policy") unless api_key?

    return if direct_outbound_api_provider == OPENROUTER_FREE_MODEL_PROVIDER

    errors.add(:config, "#{direct_outbound_runner_label} free model policy requires the OpenRouter API provider")
  end

  # @spec MODEL-POLICY-002 MODEL-POLICY-003
  def opencode_api_key_config_must_be_valid
    return unless runner_key == "opencode"
    return unless api_key?

    # @spec DIRECT-OUTBOUND-CATALOG-008
    unless OPENCODE_API_PROVIDER_KEYS.include?(opencode_api_provider)
      errors.add(:config, "must include a supported OpenCode API provider")
    end

    errors.add(:config, "must include an OpenCode model id") if opencode_model_policy != "free" && opencode_model_id.blank?

    if opencode_config["preflight_timeout_seconds"].present? &&
        (opencode_preflight_timeout_seconds.nil? || opencode_preflight_timeout_seconds < MIN_PREFLIGHT_TIMEOUT_SECONDS)
      errors.add(:config, "must include an OpenCode preflight timeout of at least #{MIN_PREFLIGHT_TIMEOUT_SECONDS} second")
    end
  end

  # @spec MODEL-POLICY-004
  def tier_model_ids_must_be_valid
    return if tier_model_ids.blank?

    unless tier_model_ids.is_a?(Hash)
      errors.add(:tier_model_ids, "must be a hash of tier => model_id")
      return
    end

    invalid_tiers = tier_model_ids.keys.map(&:to_s) - LlmModel::TIERS
    if invalid_tiers.any?
      errors.add(:tier_model_ids, "contains invalid tier(s): #{invalid_tiers.join(', ')}")
      return
    end

    expected_provider = Runners::DefaultTierModelIds::RUNNER_KEY_TO_MODEL_PROVIDER[runner_key.to_s]
    if expected_provider.nil? && !requires_direct_outbound? && !free_model_policy?
      errors.add(:tier_model_ids, "is not configurable for runner #{runner_key}")
      return
    end

    # Direct-outbound runners must map ALL tiers to the configured model.
    # Partial mappings would let unmapped tiers fall back to the global
    # LlmModel pool, reintroducing the wrong-model selection this PR fixes.
    if requires_direct_outbound? && !will_save_change_to_config?
      missing_tiers = LlmModel::TIERS.select { |t| tier_model_ids[t].blank? }
      if missing_tiers.any?
        errors.add(:tier_model_ids, "must map all tiers for direct-outbound runners (missing: #{missing_tiers.join(', ')})")
        return
      end
    end

    tier_model_ids.each do |tier, model_id|
      next if model_id.blank?

      model = LlmModel.find_by(model_id: model_id)
      if model.nil?
        errors.add(:tier_model_ids, "references unknown model #{model_id} for tier #{tier}")
      elsif free_model_policy?
        # free-policy runners route only free-pricing models. Reject crafted
        # updates that try to repoint them at paid OpenRouter models the
        # runner must never run.
        unless model.free?
          errors.add(:tier_model_ids, "must reference free models for #{runner_key} (#{model_id} is not free)")
          return
        end
      elsif requires_direct_outbound?
        # Direct-outbound runners must use their configured model — reject
        # crafted updates that try to pin a different model_id. Skip when
        # config is changing because sync_direct_outbound_tier_models will
        # overwrite tier_model_ids during save.
        next if will_save_change_to_config?
        configured = direct_outbound_model_id
        if configured.present?
          # The configured model may be provider-qualified (e.g.
          # "minimax/MiniMax-M3") while the tier_model_ids value comes from the
          # LlmModel catalog as the bare id ("MiniMax-M3"). Accept either form.
          candidates = direct_outbound_catalog_model_id_candidates(configured)
          unless candidates.include?(model_id)
            errors.add(:tier_model_ids, "must match the configured direct-outbound model #{configured}")
            return
          end
        end
      elsif expected_provider && model.provider != expected_provider
        errors.add(:tier_model_ids, "model #{model_id} does not belong to runner #{runner_key}")
      end
    end
  end

  # @spec MODEL-POLICY-004
  def tier_models_must_be_valid
    raw_tier_models = self[:tier_models]
    return if raw_tier_models.blank?

    unless raw_tier_models.is_a?(Hash)
      errors.add(:tier_models, "must be a hash of tier => { model_id, provider_id }")
      return
    end

    invalid_tiers = tier_models.keys - LlmModel::TIERS
    if invalid_tiers.any?
      errors.add(:tier_models, "contains invalid tier(s): #{invalid_tiers.join(', ')}")
      return
    end

    tier_models.each do |tier, entry|
      unless entry.is_a?(Hash)
        errors.add(:tier_models, "tier #{tier} must map to a hash with model_id and provider_id")
        next
      end

      invalid_keys = entry.keys - TIER_MODEL_VALUE_KEYS
      if invalid_keys.any?
        errors.add(:tier_models, "tier #{tier} contains unknown key(s): #{invalid_keys.join(', ')}")
      end

      model_id = entry["model_id"]
      if !model_id.is_a?(String) || model_id.blank?
        errors.add(:tier_models, "tier #{tier} must include a non-blank model_id")
      elsif free_model_policy?
        # ResolveTierModel prefers persisted tier_models over the free
        # defaults, so the free contract must also hold here.
        model = LlmModel.find_by(model_id: model_id)
        if model && !model.free?
          errors.add(:tier_models, "tier #{tier} must reference a free model for #{runner_key} (#{model_id} is not free)")
        end
      end

      provider_id = entry["provider_id"]
      next if provider_id.is_a?(Integer)

      errors.add(:tier_models, "tier #{tier} must include an integer provider_id")
    end
  end

  def complexity_thresholds_must_be_valid
    return if complexity_thresholds.blank?

    unless complexity_thresholds.is_a?(Hash)
      errors.add(:complexity_thresholds, "must be a hash of threshold keys to integers")
      return
    end

    invalid_keys = complexity_thresholds.keys.map(&:to_s) - COMPLEXITY_THRESHOLD_KEYS
    if invalid_keys.any?
      errors.add(:complexity_thresholds, "contains unknown key(s): #{invalid_keys.join(', ')}")
      return
    end

    coerced = {}
    COMPLEXITY_THRESHOLD_KEYS.each do |key|
      raw = complexity_thresholds[key] || complexity_thresholds[key.to_sym]
      next if raw.nil?

      value = Integer(raw, exception: false)
      if value.nil? || !value.between?(1, 10)
        errors.add(:complexity_thresholds, "#{key} must be an integer between 1 and 10")
        return
      end
      coerced[key] = value
    end

    # Compare against effective values so partial submissions (e.g. only low_max)
    # cannot persist a configuration that is inconsistent when merged with the
    # defaults (e.g. low_max=8 with the default mid_max=7 would leave the "mid"
    # tier unreachable).
    effective_low_max = coerced["low_max"] || DEFAULT_COMPLEXITY_THRESHOLDS["low_max"]
    effective_mid_max = coerced["mid_max"] || DEFAULT_COMPLEXITY_THRESHOLDS["mid_max"]
    return if effective_low_max < effective_mid_max

    errors.add(:complexity_thresholds, "low_max must be less than mid_max")
  end

  # Validate tier_model_ids entries against the runner compatibility contract.
  # Rejects models that are known incompatible (e.g. CLI-version-gated) while
  # treating unknown compatibility results as permissive to avoid false positives.
  # @spec MODEL-POLICY-004
  def tier_model_ids_must_be_runner_compatible
    return if tier_model_ids.blank?
    return unless tier_model_ids.is_a?(Hash)
    return if requires_direct_outbound? || free_model_policy?

    tier_model_ids.each do |tier, model_id|
      next if model_id.blank?

      result = Runners::ModelCompatibility.call(
        runner_key: runner_key,
        model_id: model_id,
        auth_type: auth_type
      )
      next unless result.unsupported?

      errors.add(
        :tier_model_ids,
        "model '#{model_id}' for tier '#{tier}' is not compatible with #{runner_key}: #{result.reason}"
      )
    end
  end

  # Validate tier_models entries against the runner compatibility contract.
  # @spec MODEL-POLICY-004
  def tier_models_must_be_runner_compatible
    raw_tier_models = self[:tier_models]
    return if raw_tier_models.blank?
    return unless raw_tier_models.is_a?(Hash)
    return if requires_direct_outbound? || free_model_policy?

    tier_models.each do |tier, entry|
      next unless entry.is_a?(Hash)

      model_id = entry["model_id"]
      next if model_id.blank?

      result = Runners::ModelCompatibility.call(
        runner_key: runner_key,
        model_id: model_id,
        auth_type: auth_type
      )
      next unless result.unsupported?

      errors.add(
        :tier_models,
        "model '#{model_id}' for tier '#{tier}' is not compatible with #{runner_key}: #{result.reason}"
      )
    end
  end

  def no_progress_thresholds_must_be_valid
    return if no_progress_thresholds.blank?

    unless no_progress_thresholds.is_a?(Hash)
      errors.add(:no_progress_thresholds, "must be a hash of threshold keys to positive integers")
      return
    end

    invalid_keys = no_progress_thresholds.keys.map(&:to_s) - NO_PROGRESS_THRESHOLD_KEYS
    if invalid_keys.any?
      errors.add(:no_progress_thresholds, "contains unknown key(s): #{invalid_keys.join(', ')}")
      return
    end

    NO_PROGRESS_THRESHOLD_KEYS.each do |key|
      raw = no_progress_thresholds[key] || no_progress_thresholds[key.to_sym]
      next if raw.nil?

      value = Integer(raw, exception: false)
      unless value&.positive?
        errors.add(:no_progress_thresholds, "#{key} must be a positive integer")
      end
    end
  end

  # @spec RUNNER-SCHED-002
  def time_restrictions_must_be_valid
    raw = self[:time_restrictions]
    return if raw.blank?
    return errors.add(:time_restrictions, "must be a hash") unless raw.is_a?(Hash)

    config = raw.deep_symbolize_keys

    mode = config[:mode].to_s
    unless Runners::TimeWindowCheck::MODES.include?(mode)
      errors.add(:time_restrictions, "mode must be one of: #{Runners::TimeWindowCheck::MODES.join(', ')}")
      return
    end

    timezone = config[:timezone].to_s.presence || "UTC"
    unless ActiveSupport::TimeZone[timezone]
      errors.add(:time_restrictions, "timezone '#{timezone}' is not a recognized IANA zone")
      return
    end

    windows = Array(config[:windows])
    if windows.empty?
      errors.add(:time_restrictions, "must include at least one window when mode is set")
      return
    end

    if windows.size > MAX_TIME_RESTRICTION_WINDOWS
      errors.add(:time_restrictions, "must not include more than #{MAX_TIME_RESTRICTION_WINDOWS} windows")
      return
    end

    parsed_windows = windows.each_with_index.filter_map do |window, index|
      unless window.is_a?(Hash)
        errors.add(:time_restrictions, "window #{index} must be a hash with start_hour and end_hour")
        next
      end

      w = window.deep_symbolize_keys
      start_h = Integer(w[:start_hour], exception: false)
      end_h = Integer(w[:end_hour], exception: false)

      unless start_h && end_h
        errors.add(:time_restrictions, "window #{index} must include integer start_hour and end_hour")
        next
      end

      unless start_h.between?(0, 23) && end_h.between?(0, 23)
        errors.add(:time_restrictions, "window #{index} hours must be between 0 and 23")
        next
      end

      if start_h == end_h
        errors.add(:time_restrictions, "window #{index} start_hour and end_hour must not be equal")
        next
      end

      [ start_h, end_h ]
    end

    return if errors.any?

    if covers_all_24_hours?(parsed_windows)
      errors.add(:time_restrictions, "windows must not cover all 24 hours (at least one hour must remain unrestricted)")
    end
  end

  def covers_all_24_hours?(parsed_windows)
    covered = Array.new(24, false)
    parsed_windows.each do |start_h, end_h|
      if start_h < end_h
        (start_h...end_h).each { |h| covered[h] = true }
      else
        (start_h...24).each { |h| covered[h] = true }
        (0...end_h).each { |h| covered[h] = true }
      end
    end
    covered.all?
  end

  def normalize_tier_models(value)
    return {} if value.blank?
    return value unless value.is_a?(Hash)

    value.each_with_object({}) do |(tier, entry), normalized|
      next if entry.blank?

      normalized[tier.to_s] = normalize_tier_model_entry(entry)
    end
  end

  def normalize_tier_model_entry(entry)
    return entry unless entry.is_a?(Hash)

    model_id = entry["model_id"] || entry[:model_id]
    provider_id = entry["provider_id"] || entry[:provider_id]

    {}.tap do |normalized|
      normalized["model_id"] = model_id.to_s if model_id.present?

      coerced_provider_id = Integer(provider_id, exception: false)
      normalized["provider_id"] = coerced_provider_id unless coerced_provider_id.nil?
    end
  end

  def kilocode_api_key_config_must_be_valid
    return unless runner_key == "kilocode"
    return unless api_key?

    # @spec DIRECT-OUTBOUND-CATALOG-008
    unless KILOCODE_API_PROVIDER_KEYS.include?(kilocode_api_provider)
      errors.add(:config, "must include a supported KiloCode API provider")
    end

    if direct_outbound_model_policy != "free" && kilocode_model_id.blank?
      errors.add(:config, "must include a KiloCode model id")
    end

    if kilocode_config["preflight_timeout_seconds"].present? &&
        (kilocode_preflight_timeout_seconds.nil? || kilocode_preflight_timeout_seconds < MIN_PREFLIGHT_TIMEOUT_SECONDS)
      errors.add(:config, "must include a KiloCode preflight timeout of at least #{MIN_PREFLIGHT_TIMEOUT_SECONDS} second")
    end
  end

  def pi_api_key_config_must_be_valid
    return unless runner_key == "pi"
    return unless api_key?

    # @spec DIRECT-OUTBOUND-CATALOG-008
    unless PI_API_PROVIDER_KEYS.include?(pi_api_provider)
      errors.add(:config, "must include a supported Pi API provider")
    end
  end

  def omp_api_key_config_must_be_valid
    return unless runner_key == "omp"
    return unless api_key?

    # @spec DIRECT-OUTBOUND-CATALOG-008
    unless OMP_API_PROVIDER_KEYS.include?(omp_api_provider)
      errors.add(:config, "must include a supported Oh My Pi API provider")
    end
  end

  # Validates that an existing catalog row for the configured model id belongs
  # to the runner's expected service_type. New explicit user-entered model ids
  # are NOT rejected here — the before_save hook
  # +ensure_manual_direct_outbound_catalog_entry+ registers a manual catalog row
  # so downstream selection has something to resolve. Provider-mismatched
  # existing rows still fail so a user can't repoint an Anthropic-catalog model
  # at a different provider.
  def direct_outbound_config_models_must_exist_in_catalog
    return unless direct_outbound_capable_runner?

    model_id = direct_outbound_model_id
    return if model_id.blank?

    model = find_direct_outbound_catalog_model(model_id)
    return if model.blank?

    expected_provider = direct_outbound_llm_model_provider
    return if expected_provider.blank? || model.provider == expected_provider

    errors.add(:config, "#{direct_outbound_runner_label} model belongs to the #{RunnerSupport.api_service_type_label(model.provider)} catalog but expected #{RunnerSupport.api_service_type_label(expected_provider)}")
  end

  def required_api_service_type
    return opencode_required_api_service_type if runner_key == "opencode"
    return kilocode_required_api_service_type if runner_key == "kilocode"
    return pi_required_api_service_type if runner_key == "pi"
    return omp_required_api_service_type if runner_key == "omp"

    self.class.api_service_type_for(runner_key)
  end
  public :required_api_service_type

  def opencode_direct_outbound?
    runner_key == "opencode" &&
      api_key? &&
      OPENCODE_API_PROVIDER_KEYS.include?(opencode_api_provider) &&
      opencode_model_id.present?
  end

  def kilocode_direct_outbound?
    runner_key == "kilocode" &&
      api_key? &&
      KILOCODE_API_PROVIDER_KEYS.include?(kilocode_api_provider) &&
      kilocode_model_id.present?
  end

  def pi_direct_outbound?
    runner_key == "pi" &&
      api_key? &&
      PI_API_PROVIDER_KEYS.include?(pi_api_provider) &&
      pi_model_id.present?
  end

  def omp_direct_outbound?
    runner_key == "omp" &&
      api_key? &&
      OMP_API_PROVIDER_KEYS.include?(omp_api_provider) &&
      omp_model_id.present?
  end

  def direct_outbound_free_policy_supported_runner?
    DIRECT_OUTBOUND_FREE_POLICY_RUNNER_KEYS.include?(runner_key)
  end

  def direct_outbound_model_policy
    return nil unless direct_outbound_free_policy_supported_runner?

    direct_outbound_config.fetch("model_policy", "").presence || "specific"
  end

  def direct_outbound_free_policy?
    direct_outbound_model_policy == "free"
  end

  def opencode_free_model_policy_runtime?
    runner_key == "opencode" && direct_outbound_free_policy? && opencode_api_provider == OPENROUTER_FREE_MODEL_PROVIDER
  end

  def kilocode_free_model_policy_runtime?
    runner_key == "kilocode" && direct_outbound_free_policy? && kilocode_api_provider == OPENROUTER_FREE_MODEL_PROVIDER
  end

  def pi_free_model_policy_runtime?
    runner_key == "pi" && direct_outbound_free_policy? && pi_api_provider == OPENROUTER_FREE_MODEL_PROVIDER
  end

  def omp_free_model_policy_runtime?
    runner_key == "omp" && direct_outbound_free_policy? && omp_api_provider == OPENROUTER_FREE_MODEL_PROVIDER
  end

  def direct_outbound_runner_label
    case runner_key
    when "opencode" then "OpenCode"
    when "kilocode" then "KiloCode"
    when "pi" then "Pi"
    when "omp" then "Oh My Pi"
    else runner_key.to_s
    end
  end

  def direct_outbound_config
    return {} unless direct_outbound_free_policy_supported_runner?
    return {} unless config.is_a?(Hash)

    config.fetch(runner_key, {})
  end

  def direct_outbound_api_provider
    case runner_key
    when "opencode" then opencode_api_provider
    when "kilocode" then kilocode_api_provider
    when "pi" then pi_api_provider
    when "omp" then omp_api_provider
    end
  end

  def direct_outbound_api_label
    case runner_key
    when "pi", "omp"
      PI_API_PROVIDERS.dig(direct_outbound_api_provider, :label)
    else
      DIRECT_OUTBOUND_API_PROVIDERS.dig(direct_outbound_api_provider, :label)
    end
  end

  def find_direct_outbound_catalog_model(model_id)
    direct_outbound_catalog_model_id_candidates(model_id)
      .lazy
      .map { |candidate| LlmModel.find_by(model_id: candidate) }
      .find(&:present?)
  end

  # New records must not default to a provider before the user has actually
  # selected an API key -- the model list depends on the selected key, and the
  # initial state should stay on "Select an API key first". Persisted rows
  # (including pre-migration rows with only a legacy config value) keep
  # falling back to `default` so existing runners don't change behavior.
  def derived_api_provider_for(api_key, legacy_value:, default:)
    return api_key.api_service_type if api_key.present?
    return legacy_value.to_s if legacy_value.present?
    return default if persisted?

    nil
  end

  def direct_outbound_catalog_model_id_candidates(model_id)
    candidates = [ model_id.to_s ]
    provider_prefix = direct_outbound_catalog_provider_prefix

    if provider_prefix.present? && model_id.start_with?("#{provider_prefix}/")
      candidates << model_id.delete_prefix("#{provider_prefix}/")
    end

    candidates.uniq
  end

  def direct_outbound_catalog_provider_prefix
    return DIRECT_OUTBOUND_API_PROVIDERS.dig(opencode_api_provider, :opencode_model_provider) if runner_key == "opencode"

    direct_outbound_llm_model_provider
  end

  def opencode_runner_runtime(project: nil)
    model_id = opencode_qualified_model
    raise ArgumentError, "Missing OpenCode model id for runner #{id || runner_key}" if model_id.blank?

    api_config = DIRECT_OUTBOUND_API_PROVIDERS.fetch(opencode_api_provider, DIRECT_OUTBOUND_API_PROVIDERS["openrouter"])

    env_var = direct_outbound_api_key_env_var(opencode_api_provider)
    env = { env_var => effective_api_secret.to_s }

    # Providers using @ai-sdk/anthropic receive their base URL through the
    # ANTHROPIC_BASE_URL env var and declare their SDK via the provider config
    # "npm" field.  OpenCode 1.3.x rejects unrecognized keys like "baseURL" in
    # provider configs, so the URL must go through the environment.
    # OPENAI_BASE_URL is only read by the OpenAI-compatible SDK.
    provider_config = {}
    if api_config[:opencode_npm] == "@ai-sdk/anthropic"
      provider_config["npm"] = api_config[:opencode_npm]
      env["ANTHROPIC_BASE_URL"] = api_config[:base_url] if api_config[:base_url]

      # Custom Anthropic-compatible endpoints (e.g. MiniMax) serve model ids the
      # @ai-sdk/anthropic SDK does not ship, so opencode's getModel rejects them
      # with ProviderModelNotFoundError before the request reaches the provider
      # — most visibly for newly released models (e.g. MiniMax-M3). Declare the
      # configured model so opencode registers and accepts it. Native Anthropic
      # is excluded: the SDK already ships its Claude models.
      if custom_anthropic_endpoint?(api_config)
        models = opencode_custom_provider_models
        provider_config["models"] = models if models
      end
    elsif custom_openai_compatible_provider?(api_config)
      # opencode ships a built-in provider for these endpoints (e.g.
      # zai-coding-plan) that reads its API key from the env var set above and
      # speaks z.ai's native request format. Only the model needs declaring —
      # opencode's catalog tops out before glm-5.x — so EXTEND the built-in
      # provider with a models entry rather than overriding it. Declaring a full
      # @ai-sdk/openai-compatible block (npm/options) here would REPLACE the
      # built-in and send requests z.ai rejects with a 500 "Unexpected server
      # error". Do NOT emit OPENAI_BASE_URL either: it only redirects the
      # unrelated built-in openai provider.
      models = opencode_custom_provider_models
      provider_config["models"] = models if models
    elsif api_config[:base_url]
      env["OPENAI_BASE_URL"] = api_config[:base_url]
    end

    AgentHarness::ProviderRuntime.new(
      model: model_id,
      env: env,
      unset_env: opencode_direct_outbound_unset_env(env),
      metadata: {
        config: opencode_runtime_metadata_config(api_config, provider_config, project)
      }
    )
  end

  # Strip Paid proxy credentials that provision.rb seeds as baseline env. Keep
  # variables explicitly set by the direct-outbound runtime because those hold
  # the real upstream key/base URL for the selected provider.
  def opencode_direct_outbound_unset_env(runtime_env) # @spec AGENT-HARNESS-004
    %w[
      OPENAI_API_KEY OPENAI_BASE_URL OPENAI_HEADER_X_AGENT_RUN_ID OPENAI_HEADER_X_PROXY_TOKEN
      ANTHROPIC_API_KEY ANTHROPIC_BASE_URL ANTHROPIC_HEADER_X_AGENT_RUN_ID ANTHROPIC_HEADER_X_PROXY_TOKEN
      GEMINI_API_KEY GEMINI_CLI_CUSTOM_HEADERS GOOGLE_API_KEY GOOGLE_GEMINI_BASE_URL GOOGLE_GENAI_BASE_URL
      GOOGLE_HEADER_X_AGENT_RUN_ID GOOGLE_HEADER_X_PROXY_TOKEN
    ] - runtime_env.keys
  end

  # True for Anthropic-SDK providers that are NOT the native Anthropic endpoint
  # (e.g. MiniMax). Their custom model ids are unknown to @ai-sdk/anthropic and
  # must be declared in the opencode provider config so opencode accepts them.
  def custom_anthropic_endpoint?(api_config)
    api_config[:opencode_npm] == "@ai-sdk/anthropic" &&
      api_config[:opencode_model_provider].to_s != "anthropic"
  end

  # True for OpenAI-compatible providers flagged :opencode_custom (e.g. z.ai
  # coding plan). opencode ships a built-in provider for them that handles auth
  # and z.ai's native request format, but its catalog lacks glm-5.x, so the
  # configured model is declared as an extension to the built-in provider
  # (opencode_runner_runtime) rather than overriding it.
  def custom_openai_compatible_provider?(api_config)
    api_config[:opencode_custom] == true
  end

  # opencode model declaration keyed by the bare model id — the segment after
  # the provider prefix in "<provider>/<model>", matching how opencode parses
  # the runtime model string. Returns nil when no model is configured.
  def opencode_custom_provider_models
    bare_id = opencode_bare_model_id
    return if bare_id.blank?

    { bare_id => { "name" => bare_id } }
  end

  def opencode_bare_model_id
    qualified = opencode_qualified_model.to_s
    prefix = DIRECT_OUTBOUND_API_PROVIDERS.dig(opencode_api_provider, :opencode_model_provider).to_s
    return qualified if prefix.blank? || !qualified.start_with?("#{prefix}/")

    qualified.delete_prefix("#{prefix}/")
  end

  def opencode_runtime_metadata_config(api_config, provider_config, project)
    provider_metadata = {}

    unless provider_config.empty?
      # provider_config is populated for @ai-sdk/anthropic entries and for
      # :opencode_custom entries that extend a built-in provider with a model
      # opencode's catalog lacks; both always declare opencode_model_provider.
      # fetch (not ||) so a future entry that forgets it fails loudly instead of
      # silently mislabeling the block.
      provider_key = api_config.fetch(:opencode_model_provider)
      provider_metadata[provider_key] = provider_config
    end

    if project.present? && api_config[:service_type] == OPENROUTER_FREE_MODEL_PROVIDER
      provider_metadata["openrouter"] = provider_metadata.fetch("openrouter", {}).merge(build_provider_routing(project))
    end

    provider_metadata.any? ? { "provider" => provider_metadata } : {}
  end

  def pi_runner_runtime
    AgentHarness::ProviderRuntime.new(
      model: pi_model_id,
      api_provider: pi_api_provider,
      metadata: {
        "paid_pi_auth_entry" => {
          "provider" => pi_api_provider,
          "api_key" => effective_api_secret.to_s
        }
      }
    )
  end

  def omp_runner_runtime
    AgentHarness::ProviderRuntime.new(
      model: omp_model_id,
      api_provider: omp_api_provider,
      env: omp_runtime_env
    )
  end

  # Shared builder for OpenRouter-backed free-policy runners. Resolves the
  # model via Runners::FreeModelExecutionPlan and translates it into the
  # AgentHarness runtime.
  def openrouter_provider_runtime(config)
    AgentHarness::ProviderRuntime.new(
      model: config.fetch(:model),
      env: {
        config.fetch(:api_key_env) => effective_api_secret.to_s,
        "OPENAI_BASE_URL" => config.fetch(:base_url)
      },
      unset_env: %w[OPENAI_HEADER_X_AGENT_RUN_ID OPENAI_HEADER_X_PROXY_TOKEN],
      metadata: {
        config: {
          "provider" => {
            "openrouter" => config.fetch(:provider_routing)
          }
        }
      }
    )
  end
  private :openrouter_provider_runtime

  def free_model_policy_runner_runtime(project:, model_id:)
    free_policy_direct_outbound_runtime(project: project, model_id: model_id)
  end
  public :free_model_policy_runner_runtime

  def free_policy_direct_outbound_runtime(project:, model_id:)
    model_id ||= free_policy_default_model_id
    raise ArgumentError, "#{runner_key} runner has no resolvable free model" if model_id.blank?

    config = Runners::FreeModelExecutionPlan.call(runner: self, model_id: model_id, project: project).config

    case runner_key
    when "kilocode"
      kilocode_free_policy_runtime(config)
    when "pi"
      pi_free_policy_runtime(config)
    when "omp"
      omp_free_policy_runtime(config)
    else
      openrouter_provider_runtime(config)
    end
  end

  def pi_free_policy_runtime(config)
    AgentHarness::ProviderRuntime.new(
      model: config.fetch(:model),
      api_provider: pi_api_provider,
      env: {
        config.fetch(:api_key_env) => effective_api_secret.to_s,
        "OPENAI_BASE_URL" => config.fetch(:base_url)
      },
      unset_env: %w[OPENAI_HEADER_X_AGENT_RUN_ID OPENAI_HEADER_X_PROXY_TOKEN],
      metadata: {
        "paid_pi_auth_entry" => {
          "provider" => pi_api_provider,
          "api_key" => effective_api_secret.to_s
        },
        config: {
          "provider" => {
            "openrouter" => config.fetch(:provider_routing)
          }
        }
      }
    )
  end

  def omp_free_policy_runtime(config)
    AgentHarness::ProviderRuntime.new(
      model: config.fetch(:model),
      api_provider: omp_api_provider,
      env: omp_runtime_env.merge("OPENAI_BASE_URL" => config.fetch(:base_url)),
      unset_env: %w[OPENAI_HEADER_X_AGENT_RUN_ID OPENAI_HEADER_X_PROXY_TOKEN],
      metadata: {
        config: {
          "provider" => {
            "openrouter" => config.fetch(:provider_routing)
          }
        }
      }
    )
  end

  def kilocode_free_policy_runtime(config)
    model_id = config.fetch(:model)
    options = {
      "apiKey" => "{env:#{config.fetch(:api_key_env)}}",
      "baseURL" => config.fetch(:base_url),
      "providerRouting" => config.fetch(:provider_routing)
    }

    AgentHarness::ProviderRuntime.new(
      model: kilocode_qualified_model("openai-compatible", model_id),
      env: kilocode_runtime_env,
      metadata: {
        config: {
          "provider" => {
            "openai-compatible" => {
              "options" => options,
              "models" => {
                model_id => {
                  "name" => model_id,
                  "id" => model_id,
                  "tool_call" => true
                }
              }
            }
          },
          "permission" => {
            "external_directory" => KILOCODE_EXTERNAL_DIRECTORY_PERMISSIONS
          }
        }
      }
    )
  end

  # Resolves the highest-tier free model for config-blind dispatch paths such
  # as chat planning and compatibility checks. Live agent-run execution passes
  # an explicit model_id from model selection / tier resolution instead.
  def free_policy_default_model_id
    return @free_policy_default_model_id if defined?(@free_policy_default_model_id)

    @free_policy_default_model_id = LlmModel::TIERS.reverse.filter_map do |tier|
      result = Runners::ResolveTierModel.call(runner: self, tier: tier, user: user)
      result.model_id if result.success? && result.model_id.present?
    end.first
  end

  def omp_api_key_env_var
    api_config = OMP_API_PROVIDERS[omp_api_provider.to_s]
    return "OPENAI_API_KEY" if api_config.blank?

    api_config[:env_var].presence || "#{api_config[:service_type].upcase.tr('-', '_')}_API_KEY"
  end

  def omp_runtime_env
    api_key = effective_api_secret.to_s
    return {} if api_key.blank?

    { omp_api_key_env_var => api_key }
  end

  def kilocode_harness_provider
    klass = AgentHarness.provider_class(:kilocode)
    config = AgentHarness.build_config(:kilocode)
    config.externally_sandboxed = true

    klass.new(config: config)
  end
  private :kilocode_harness_provider
end
