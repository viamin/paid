# frozen_string_literal: true

require "base64"
require "set"
require "shellwords"

class Runner < ApplicationRecord
  has_logidze
  include Discard::Model
  include LegacyAttributeBridge

  LEGACY_PROVIDER_ATTRIBUTE_BRIDGES = {
    "provider_key" => "runner_key"
  }.freeze
  AUTH_TYPES = %w[subscription api_key].freeze
  FALLBACK_ROLES = %w[standard rate_limit_fallback].freeze
  ROUTING_KEY_PREFIX = "runner:".freeze
  LEGACY_ROUTING_KEY_PREFIX = "provider:".freeze
  DEFAULT_WEIGHT = 1
  MAX_WEIGHT = 1000
  # Default cutoffs for mapping a complexity score (1-10) to an LlmModel tier.
  # complexity <= low_max => "low", <= mid_max => "mid", else "high".
  DEFAULT_COMPLEXITY_THRESHOLDS = { "low_max" => 3, "mid_max" => 7 }.freeze
  COMPLEXITY_THRESHOLD_KEYS = %w[low_max mid_max].freeze
  # Upstream API providers supported by direct-outbound CLI tools (OpenCode,
  # KiloCode). Each entry maps a slug to its base URL and the ProviderApiKey
  # service type required for authentication.
  # Each entry carries an adapter hint so config generators can distinguish
  # OpenAI-compatible endpoints from providers with a native SDK (Anthropic).
  # The opencode_npm / kilocode_api keys default to the openai-compatible
  # adapter and are overridden only for Anthropic.
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
                   env_var: "ANTHROPIC_API_KEY", opencode_npm: "@ai-sdk/anthropic", kilocode_provider_id: "anthropic" },
    "xai" => { label: "xAI", base_url: "https://api.x.ai/v1", service_type: "xai",
               opencode_model_provider: "xai" },
    "zai" => { label: "z.ai", base_url: "https://api.z.ai/api/paas/v4", service_type: "zai",
               opencode_model_provider: "zai" },
    "zai_coding" => { label: "z.ai (Coding Plan)", base_url: "https://api.z.ai/api/coding/paas/v4", service_type: "zai_coding",
                      kilocode_provider_id: "zai-coding-plan", opencode_model_provider: "zai_coding" }
  }.freeze

  DIRECT_OUTBOUND_SERVICE_TYPES = DIRECT_OUTBOUND_API_PROVIDERS.values.map { |c| c[:service_type] }.to_set.freeze
  OPENAI_COMPATIBLE_DIRECT_OUTBOUND_API_PROVIDER_KEYS = DIRECT_OUTBOUND_API_PROVIDERS.filter_map do |provider_key, config|
    provider_key if (config[:opencode_npm] || "@ai-sdk/openai-compatible") == "@ai-sdk/openai-compatible"
  end.freeze

  OPENCODE_API_PROVIDER_KEYS = DIRECT_OUTBOUND_API_PROVIDERS.keys.freeze
  OPENCODE_DEFAULT_API_PROVIDER = "openrouter"

  KILOCODE_API_PROVIDER_KEYS = DIRECT_OUTBOUND_API_PROVIDERS.keys.freeze
  KILOCODE_DEFAULT_API_PROVIDER = "anthropic"

  AIDER_API_PROVIDER_KEYS = DIRECT_OUTBOUND_API_PROVIDERS.keys.freeze
  AIDER_DEFAULT_API_PROVIDER = "openrouter"

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

  DIRECT_OUTBOUND_MODEL_TIER_HINTS = {
    "glm-5.1" => "high",
    "glm-4.7" => "mid",
    "glm-4.5-air" => "low"
  }.freeze

  belongs_to :user
  belongs_to :provider_api_key, optional: true

  has_many :chat_sessions, dependent: :nullify

  scope :kept_only, -> { kept }
  scope :for_agent_runs, -> { where(enabled_for_agent_runs: true) }
  scope :for_fallback, -> { where(enabled_for_fallback: true) }
  scope :ordered, -> { order(:runner_key, :auth_type, :name, :id) }
  scope :subscription, -> { where(auth_type: "subscription") }
  scope :api_key, -> { where(auth_type: "api_key") }
  scope :rate_limit_fallback, -> { where(fallback_role: "rate_limit_fallback") }

  before_validation :normalize_agent_co_author_trailer
  before_validation :sync_provider_key_bridge
  before_validation :clear_stale_direct_outbound_tier_models
  before_save :sync_direct_outbound_tier_models
  before_discard :prevent_destroying_last_agent_run_runner
  before_discard :prevent_destroying_default_runner
  before_discard :clear_provider_api_key_reference
  after_commit :invalidate_agent_run_runner_option_caches, if: :agent_run_runner_option_cache_invalidation_needed?

  validates :weight, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: MAX_WEIGHT }
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
  validate :subscription_must_have_standard_fallback_role
  validate :api_key_entry_must_be_unique
  validate :opencode_api_key_config_must_be_valid
  validate :kilocode_api_key_config_must_be_valid
  validate :aider_api_key_config_must_be_valid
  validate :pi_api_key_config_must_be_valid
  validate :tier_model_ids_must_be_valid
  validate :complexity_thresholds_must_be_valid
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

  def display_name
    return name if name.present?

    label = self.class.display_name_for(runner_key)
    model_id = case runner_key
    when "opencode" then opencode_model_id
    when "kilocode" then kilocode_model_id
    when "aider" then aider_model_id
    when "pi" then pi_model_id
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

  def legacy_routing_key
    persisted? ? "#{LEGACY_ROUTING_KEY_PREFIX}#{id}" : runner_key.to_s
  end

  def opencode_config
    config.is_a?(Hash) ? config.fetch("opencode", {}) : {}
  end

  def opencode_api_provider
    return nil unless runner_key == "opencode"

    opencode_config["api_provider"].presence || OPENCODE_DEFAULT_API_PROVIDER
  end

  def opencode_model_id
    return nil unless runner_key == "opencode"

    opencode_config["model"].to_s.presence
  end

  def kilocode_config
    config.is_a?(Hash) ? config.fetch("kilocode", {}) : {}
  end

  def kilocode_api_provider
    return nil unless runner_key == "kilocode"

    kilocode_config["api_provider"].presence || KILOCODE_DEFAULT_API_PROVIDER
  end

  def kilocode_model_id
    return nil unless runner_key == "kilocode"

    kilocode_config["model"].to_s.presence
  end

  def kilocode_required_api_service_type
    return nil unless runner_key == "kilocode"

    DIRECT_OUTBOUND_API_PROVIDERS.dig(kilocode_api_provider, :service_type)
  end

  def aider_config
    config.is_a?(Hash) ? config.fetch("aider", {}) : {}
  end

  def aider_api_provider
    return nil unless runner_key == "aider"

    aider_config["api_provider"].presence || AIDER_DEFAULT_API_PROVIDER
  end

  def aider_model_id
    return nil unless runner_key == "aider"

    aider_config["model"].to_s.presence
  end

  def pi_config
    config.is_a?(Hash) ? config.fetch("pi", {}) : {}
  end

  def pi_api_provider
    return nil unless runner_key == "pi"

    pi_config["api_provider"].presence || PI_DEFAULT_API_PROVIDER
  end

  def pi_model_id
    return nil unless runner_key == "pi"

    pi_config["model"].to_s.presence
  end

  def pi_required_api_service_type
    return nil unless runner_key == "pi"

    PI_API_PROVIDERS.dig(pi_api_provider, :service_type)
  end

  def aider_required_api_service_type
    return nil unless runner_key == "aider"

    DIRECT_OUTBOUND_API_PROVIDERS.dig(aider_api_provider, :service_type)
  end

  # NOTE: Aider is excluded here because the execution path does not yet have
  # direct-outbound plumbing (no agent_harness_runner_runtime, no
  # direct_outbound_exec_env/exec_command support). The config infrastructure
  # (aider_config, aider_api_provider, aider_model_id) exists as prep work;
  # add aider_direct_outbound? here once the runtime path is implemented.
  def requires_direct_outbound?
    opencode_direct_outbound? || kilocode_direct_outbound? || pi_direct_outbound?
  end

  def opencode_required_api_service_type
    return nil unless runner_key == "opencode"

    DIRECT_OUTBOUND_API_PROVIDERS.dig(opencode_api_provider, :service_type)
  end

  def kilocode_config_json
    model_id = kilocode_model_id
    raise ArgumentError, "Missing KiloCode model id for runner #{id || runner_key}" if model_id.blank?

    api_config = DIRECT_OUTBOUND_API_PROVIDERS.fetch(kilocode_api_provider, DIRECT_OUTBOUND_API_PROVIDERS["anthropic"])
    kilocode_provider_id = api_config[:kilocode_provider_id] || "openai-compatible"
    options = { "apiKey" => "{env:#{kilocode_api_key_env_var}}" }
    base_url = api_config[:base_url]
    default_openai_url = DIRECT_OUTBOUND_API_PROVIDERS.dig("openai", :base_url)
    options["baseURL"] = base_url if base_url.present? && base_url != default_openai_url

    {
      provider: {
        kilocode_provider_id => {
          options: options,
          models: {
            model_id => {
              name: model_id,
              id: model_id,
              tool_call: true
            }
          }
        }
      },
      model: kilocode_qualified_model(kilocode_provider_id, model_id)
    }.to_json
  end

  def kilocode_qualified_model(provider_id, model_id)
    model_id.start_with?("#{provider_id}/") ? model_id : "#{provider_id}/#{model_id}"
  end

  def opencode_qualified_model
    model_id = opencode_model_id
    return if model_id.blank?

    api_config = DIRECT_OUTBOUND_API_PROVIDERS.fetch(opencode_api_provider, DIRECT_OUTBOUND_API_PROVIDERS["openrouter"])
    provider_id = api_config[:opencode_model_provider]
    return model_id if provider_id.blank? || model_id.start_with?("#{provider_id}/")

    "#{provider_id}/#{model_id}"
  end

  def kilocode_api_key_env_var
    api_config = DIRECT_OUTBOUND_API_PROVIDERS[kilocode_api_provider.to_s]
    return "OPENAI_API_KEY" if api_config.blank?

    api_config[:env_var].presence || "#{api_config[:service_type].upcase.tr('-', '_')}_API_KEY"
  end

  def kilocode_runtime_env
    api_key = provider_api_key&.api_key.to_s
    return {} if api_key.blank?

    { kilocode_api_key_env_var => api_key }
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
      mkdir -p /home/agent/.config/kilo &&
      printf '%s' "$PAID_KILOCODE_CONFIG_B64" | base64 -d > /home/agent/.config/kilo/config.json &&
      #{command}
    SH

    [ "sh", "-lc", script, "--", prompt ]
  end

  def agent_harness_runner_runtime
    return opencode_runner_runtime if opencode_direct_outbound?
    return pi_runner_runtime if pi_agent_harness_runtime?

    nil
  end

  def agent_harness_runtime?
    opencode_agent_harness_runtime? || copilot_agent_harness_runtime? || pi_agent_harness_runtime?
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

  def direct_outbound_model_id
    case runner_key
    when "kilocode" then kilocode_model_id
    when "opencode" then opencode_model_id
    when "aider" then aider_model_id
    when "pi" then pi_model_id
    end
  end

  def direct_outbound_llm_model_provider
    case runner_key
    when "kilocode" then kilocode_required_api_service_type
    when "opencode" then opencode_required_api_service_type
    when "aider" then aider_required_api_service_type
    when "pi" then pi_required_api_service_type
    end
  end

  def ensure_direct_outbound_llm_model!
    model_id = direct_outbound_model_id
    raise ArgumentError, "No direct-outbound model configured" if model_id.blank?

    provider_slug = direct_outbound_llm_model_provider || "unknown"
    tier = DIRECT_OUTBOUND_MODEL_TIER_HINTS[model_id] || "mid"

    model = LlmModel.find_or_create_by!(model_id: model_id) do |m|
      m.display_name = direct_outbound_display_name(model_id)
      m.provider = provider_slug
      m.category = "coding"
      m.tier = tier
      m.active = true
    end
    # Reactivate if an existing row was returned inactive — model selection
    # resolves via LlmModel.active so an inactive record would silently
    # fall back to the global pool.
    model.update!(active: true, provider: provider_slug, tier: tier) unless model.active?
    model
  rescue ActiveRecord::RecordNotUnique
    LlmModel.find_by!(model_id: model_id)
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

    relation.find_or_create_by!(runner_key: key, auth_type: "subscription")
  rescue ActiveRecord::RecordNotUnique => e
    if primary_key_conflict?(e)
      connection.reset_pk_sequence!(table_name)
      retry
    end

    relation.find_by!(runner_key: key, auth_type: "subscription")
  end

  def self.first_enabled_for_owner(owner)
    return unless owner

    executable_keys = RunnerSupport.container_executable_runner_keys
    owner.runners.kept_only.for_agent_runs.where(runner_key: executable_keys).ordered.first
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

  def sync_direct_outbound_tier_models
    return unless requires_direct_outbound?
    return unless direct_outbound_model_id.present?
    return unless will_save_change_to_config? || tier_model_ids.blank?

    model = ensure_direct_outbound_llm_model!
    self.tier_model_ids = LlmModel::TIERS.each_with_object({}) { |t, h| h[t] = model.model_id }
  end

  def clear_stale_direct_outbound_tier_models
    return unless tier_model_ids.present?
    return unless direct_outbound_capable_runner?
    return if requires_direct_outbound? && direct_outbound_model_id.present?

    self.tier_model_ids = {}
  end

  def direct_outbound_capable_runner?
    # NOTE: Aider is intentionally excluded — it is still mapped as a standard
    # Anthropic runner in DefaultTierModelIds::RUNNER_KEY_TO_MODEL_PROVIDER,
    # so including it here would cause clear_stale_direct_outbound_tier_models
    # to erase its valid standard tier mappings on every save.
    %w[kilocode opencode pi].include?(runner_key)
  end

  def direct_outbound_display_name(model_id)
    base = model_id.include?("/") ? model_id.split("/").last : model_id
    base.tr("_-", " ").split.map(&:capitalize).join(" ")
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

  def display_name_config_changed?
    previous_config, current_config = previous_changes["config"]
    return false unless previous_changes.key?("config")

    display_name_config_value(previous_config) != display_name_config_value(current_config)
  end

  def display_name_config_value(config_value)
    config = config_value.is_a?(Hash) ? config_value : {}

    case runner_key
    when "opencode"
      config.dig("opencode", "model")
    when "kilocode"
      config.dig("kilocode", "model")
    when "aider"
      config.dig("aider", "model")
    when "pi"
      config.dig("pi", "model")
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
    return if provider_api_key.present?

    errors.add(:provider_api_key, "is required for API key authentication")
  end

  def subscription_auth_must_not_have_api_key
    return unless subscription?
    return if provider_api_key_id.blank?

    errors.add(:provider_api_key, "must not be set for subscription authentication")
  end

  def api_key_must_be_compatible
    return unless api_key?
    return if provider_api_key_id.blank?
    return unless provider_api_key

    required_service = required_api_service_type

    if required_service.nil?
      errors.add(:provider_api_key, "is not supported for this runner; use subscription authentication instead")
      return
    end

    return if provider_api_key.api_service_type == required_service

    errors.add(:provider_api_key, "must be an API key for #{RunnerSupport.api_service_type_label(required_service)}")
  end

  def api_key_must_belong_to_same_account
    return unless api_key?
    return if provider_api_key_id.blank?
    return unless provider_api_key
    return if provider_api_key.user&.account_id == user&.account_id

    errors.add(:provider_api_key, "must belong to the same account")
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
      provider_api_key_id: provider_api_key_id
    ).where.not(id: id).where("COALESCE(name, '') = ?", normalized_name).exists?
    return unless duplicate

    errors.add(:runner_key, "already has an entry with this API key")
  end

  def opencode_api_key_config_must_be_valid
    return unless runner_key == "opencode"
    return unless api_key?

    unless OPENCODE_API_PROVIDER_KEYS.include?(opencode_api_provider)
      errors.add(:config, "must include a supported OpenCode API provider")
    end

    if opencode_model_id.blank?
      errors.add(:config, "must include an OpenCode model id")
    end
  end

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
    if expected_provider.nil? && !requires_direct_outbound?
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
      elsif requires_direct_outbound?
        # Direct-outbound runners must use their configured model — reject
        # crafted updates that try to pin a different model_id. Skip when
        # config is changing because sync_direct_outbound_tier_models will
        # overwrite tier_model_ids during save.
        next if will_save_change_to_config?
        configured = direct_outbound_model_id
        if configured.present? && model_id != configured
          errors.add(:tier_model_ids, "must match the configured direct-outbound model #{configured}")
          return
        end
      elsif expected_provider && model.provider != expected_provider
        errors.add(:tier_model_ids, "model #{model_id} does not belong to runner #{runner_key}")
      end
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

  def kilocode_api_key_config_must_be_valid
    return unless runner_key == "kilocode"
    return unless api_key?

    unless KILOCODE_API_PROVIDER_KEYS.include?(kilocode_api_provider)
      errors.add(:config, "must include a supported KiloCode API provider")
    end

    if kilocode_model_id.blank?
      errors.add(:config, "must include a KiloCode model id")
    end
  end

  # NOTE: The runner UI/controller does not yet permit nested aider config
  # keys (api_provider, model). This validation is prep work for when the
  # controller is updated to support Aider API-key runners.
  #
  # Guard: RunnerResolver#tenant_api_key_runner auto-materializes api_key
  # runners without config. Those tenant-key entries must remain valid —
  # only enforce config requirements when aider-specific config is present.
  def aider_api_key_config_must_be_valid
    return unless runner_key == "aider"
    return unless api_key?
    return unless config.is_a?(Hash) && config.key?("aider")

    unless AIDER_API_PROVIDER_KEYS.include?(aider_api_provider)
      errors.add(:config, "must include a supported Aider API provider")
    end

    if aider_model_id.blank?
      errors.add(:config, "must include an Aider model id")
    end
  end

  def pi_api_key_config_must_be_valid
    return unless runner_key == "pi"
    return unless api_key?

    unless PI_API_PROVIDER_KEYS.include?(pi_api_provider)
      errors.add(:config, "must include a supported Pi API provider")
    end
  end

  def required_api_service_type
    return opencode_required_api_service_type if runner_key == "opencode"
    return kilocode_required_api_service_type if runner_key == "kilocode"
    return aider_required_api_service_type if runner_key == "aider"
    return pi_required_api_service_type if runner_key == "pi"

    self.class.api_service_type_for(runner_key)
  end

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

  def aider_direct_outbound?
    runner_key == "aider" &&
      api_key? &&
      AIDER_API_PROVIDER_KEYS.include?(aider_api_provider) &&
      aider_model_id.present?
  end

  def pi_direct_outbound?
    runner_key == "pi" &&
      api_key? &&
      PI_API_PROVIDER_KEYS.include?(pi_api_provider) &&
      pi_model_id.present?
  end

  def opencode_runner_runtime
    model_id = opencode_qualified_model
    raise ArgumentError, "Missing OpenCode model id for runner #{id || runner_key}" if model_id.blank?

    api_config = DIRECT_OUTBOUND_API_PROVIDERS.fetch(opencode_api_provider, DIRECT_OUTBOUND_API_PROVIDERS["openrouter"])

    env_var = direct_outbound_api_key_env_var(opencode_api_provider)
    env = { env_var => provider_api_key&.api_key.to_s }

    # Providers using @ai-sdk/anthropic receive their base URL through the
    # provider config (OPENAI_BASE_URL is only read by the OpenAI-compatible SDK).
    provider_config = {}
    if api_config[:opencode_npm] == "@ai-sdk/anthropic" && api_config[:base_url]
      provider_config["baseURL"] = api_config[:base_url]
    elsif api_config[:base_url]
      env["OPENAI_BASE_URL"] = api_config[:base_url]
    end

    AgentHarness::ProviderRuntime.new(
      model: model_id,
      env: env,
      unset_env: %w[OPENAI_HEADER_X_AGENT_RUN_ID OPENAI_HEADER_X_PROXY_TOKEN],
      metadata: {
        config: {
          "provider" => { opencode_api_provider => provider_config }
        }
      }
    )
  end

  def pi_runner_runtime
    AgentHarness::ProviderRuntime.new(
      model: pi_model_id,
      api_provider: pi_api_provider,
      metadata: {
        "paid_pi_auth_entry" => {
          "provider" => pi_api_provider,
          "api_key" => provider_api_key&.api_key.to_s
        }
      }
    )
  end
end
