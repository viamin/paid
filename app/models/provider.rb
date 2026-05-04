# frozen_string_literal: true

require "base64"
require "set"
require "shellwords"

class Provider < ApplicationRecord
  AUTH_TYPES = %w[subscription api_key].freeze
  FALLBACK_ROLES = %w[standard rate_limit_fallback].freeze
  ROUTING_KEY_PREFIX = "provider:".freeze
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
                     opencode_npm: "@ai-sdk/anthropic", kilocode_provider_id: "anthropic" },
    "openai" => { label: "OpenAI", base_url: "https://api.openai.com/v1", service_type: "openai",
                  kilocode_provider_id: "openai" },
    "inception" => { label: "InceptionLabs", base_url: "https://api.inceptionlabs.ai/v1", service_type: "inception",
                     kilocode_provider_id: "inception" },
    "deepseek" => { label: "DeepSeek", base_url: "https://api.deepseek.com/v1", service_type: "deepseek" },
    "mistral" => { label: "Mistral", base_url: "https://api.mistral.ai/v1", service_type: "mistral" },
    "xai" => { label: "xAI", base_url: "https://api.x.ai/v1", service_type: "xai" },
    "zai" => { label: "z.ai", base_url: "https://api.z.ai/api/paas/v4", service_type: "zai" },
    "zai_coding" => { label: "z.ai (Coding Plan)", base_url: "https://api.z.ai/api/coding/paas/v4", service_type: "zai_coding",
                      kilocode_provider_id: "zai-coding-plan" }
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

  DIRECT_OUTBOUND_MODEL_TIER_HINTS = {
    "glm-5.1" => "high",
    "glm-4.7" => "mid",
    "glm-4.5-air" => "low"
  }.freeze

  belongs_to :user
  belongs_to :provider_api_key, optional: true

  has_many :chat_sessions, dependent: :nullify

  scope :for_agent_runs, -> { where(enabled_for_agent_runs: true) }
  scope :for_fallback, -> { where(enabled_for_fallback: true) }
  scope :ordered, -> { order(:provider_key, :auth_type, :name, :id) }
  scope :subscription, -> { where(auth_type: "subscription") }
  scope :api_key, -> { where(auth_type: "api_key") }
  scope :rate_limit_fallback, -> { where(fallback_role: "rate_limit_fallback") }

  before_validation :normalize_agent_co_author_trailer
  before_save :sync_direct_outbound_tier_models

  validates :weight, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: MAX_WEIGHT }
  validates :provider_key, presence: true, length: { maximum: 50 }
  validates :provider_key, inclusion: { in: ->(_) { supported_provider_keys }, message: "is not supported" },
    allow_blank: true, if: -> { new_record? || will_save_change_to_provider_key? }
  validates :auth_type, presence: true, inclusion: { in: AUTH_TYPES }
  validates :fallback_role, presence: true, inclusion: { in: FALLBACK_ROLES }
  validates :name, length: { maximum: 100 }
  validates :provider_key,
    uniqueness: { scope: [ :user_id, :auth_type ], message: "already has a subscription entry" },
    if: -> { subscription? }

  validate :must_keep_at_least_one_agent_run_provider
  validate :default_provider_must_remain_enabled_for_agent_runs
  validate :api_key_auth_requires_provider_api_key
  validate :subscription_auth_must_not_have_api_key
  validate :api_key_must_be_compatible
  validate :api_key_must_belong_to_same_account
  validate :subscription_must_have_standard_fallback_role
  validate :api_key_entry_must_be_unique
  validate :opencode_api_key_config_must_be_valid
  validate :kilocode_api_key_config_must_be_valid
  validate :aider_api_key_config_must_be_valid
  validate :tier_model_ids_must_be_valid
  validate :complexity_thresholds_must_be_valid
  validate :agent_co_author_trailer_is_single_line

  before_destroy :prevent_destroying_last_agent_run_provider
  before_destroy :prevent_destroying_default_provider

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

    label = self.class.display_name_for(provider_key)
    model_id = case provider_key
    when "opencode" then opencode_model_id
    when "kilocode" then kilocode_model_id
    when "aider" then aider_model_id
    end
    label += " #{model_id}" if model_id.present?
    label += " (API Key)" if api_key?
    label
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
    persisted? ? "#{ROUTING_KEY_PREFIX}#{id}" : provider_key.to_s
  end

  def matches_identifier?(identifier)
    id_str = identifier.to_s
    return true if id_str == routing_key || id_str == provider_key.to_s

    # Also match agent_type identifiers (e.g. "claude_code") that map
    # to this provider's key (e.g. "claude") so that legacy final_provider
    # values are handled correctly.
    normalized = ProviderSupport.provider_key_for_agent_type(id_str)
    normalized != id_str && normalized == provider_key.to_s
  end

  def state_key
    subscription? ? provider_key.to_s : routing_key
  end

  def opencode_config
    config.is_a?(Hash) ? config.fetch("opencode", {}) : {}
  end

  def opencode_api_provider
    return nil unless provider_key == "opencode"

    opencode_config["api_provider"].presence || OPENCODE_DEFAULT_API_PROVIDER
  end

  def opencode_model_id
    return nil unless provider_key == "opencode"

    opencode_config["model"].to_s.presence
  end

  def kilocode_config
    config.is_a?(Hash) ? config.fetch("kilocode", {}) : {}
  end

  def kilocode_api_provider
    return nil unless provider_key == "kilocode"

    kilocode_config["api_provider"].presence || KILOCODE_DEFAULT_API_PROVIDER
  end

  def kilocode_model_id
    return nil unless provider_key == "kilocode"

    kilocode_config["model"].to_s.presence
  end

  def kilocode_required_api_service_type
    return nil unless provider_key == "kilocode"

    DIRECT_OUTBOUND_API_PROVIDERS.dig(kilocode_api_provider, :service_type)
  end

  def aider_config
    config.is_a?(Hash) ? config.fetch("aider", {}) : {}
  end

  def aider_api_provider
    return nil unless provider_key == "aider"

    aider_config["api_provider"].presence || AIDER_DEFAULT_API_PROVIDER
  end

  def aider_model_id
    return nil unless provider_key == "aider"

    aider_config["model"].to_s.presence
  end

  def aider_required_api_service_type
    return nil unless provider_key == "aider"

    DIRECT_OUTBOUND_API_PROVIDERS.dig(aider_api_provider, :service_type)
  end

  # NOTE: Aider is excluded here because the execution path does not yet have
  # direct-outbound plumbing (no agent_harness_provider_runtime, no
  # direct_outbound_exec_env/exec_command support). The config infrastructure
  # (aider_config, aider_api_provider, aider_model_id) exists as prep work;
  # add aider_direct_outbound? here once the runtime path is implemented.
  def requires_direct_outbound?
    opencode_direct_outbound? || kilocode_direct_outbound?
  end

  def opencode_required_api_service_type
    return nil unless provider_key == "opencode"

    DIRECT_OUTBOUND_API_PROVIDERS.dig(opencode_api_provider, :service_type)
  end

  def kilocode_config_json
    model_id = kilocode_model_id
    raise ArgumentError, "Missing KiloCode model id for provider #{id || provider_key}" if model_id.blank?

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
    service_type = kilocode_required_api_service_type
    return "OPENAI_API_KEY" if service_type.blank?

    "#{service_type.upcase.tr('-', '_')}_API_KEY"
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

  def agent_harness_provider_runtime
    return opencode_provider_runtime if opencode_direct_outbound?

    nil
  end

  def agent_harness_runtime?
    opencode_agent_harness_runtime? || copilot_agent_harness_runtime?
  end

  def opencode_agent_harness_runtime?
    provider_key == "opencode" && requires_direct_outbound?
  end

  def copilot_agent_harness_runtime?
    provider_key == "copilot"
  end

  def direct_outbound_model_id
    case provider_key
    when "kilocode" then kilocode_model_id
    when "opencode" then opencode_model_id
    when "aider" then aider_model_id
    end
  end

  def direct_outbound_llm_model_provider
    case provider_key
    when "kilocode" then kilocode_required_api_service_type
    when "opencode" then opencode_required_api_service_type
    when "aider" then aider_required_api_service_type
    end
  end

  def ensure_direct_outbound_llm_model!
    model_id = direct_outbound_model_id
    raise ArgumentError, "No direct-outbound model configured" if model_id.blank?

    provider_slug = direct_outbound_llm_model_provider || "unknown"
    tier = DIRECT_OUTBOUND_MODEL_TIER_HINTS[model_id] || "mid"

    LlmModel.find_or_create_by!(model_id: model_id) do |m|
      m.display_name = direct_outbound_display_name(model_id)
      m.provider = provider_slug
      m.category = "coding"
      m.tier = tier
      m.active = true
    end
  rescue ActiveRecord::RecordNotUnique
    LlmModel.find_by!(model_id: model_id)
  end

  # Returns the provider key that must always exist and remain enabled for
  # agent runs. Returns the first container-executable provider key in
  # supported order, with no hardcoded preference for any specific provider.
  # Returns nil when no container-executable providers are available, so
  # callers can surface a user-facing error instead of a 500.
  def self.default_provider_key
    ProviderSupport.container_executable_provider_keys.first
  end

  def self.ensure_default_for(user)
    key = default_provider_key
    return unless key

    user.providers.find_or_create_by!(provider_key: key, auth_type: "subscription")
  rescue ActiveRecord::RecordNotUnique
    user.providers.find_by!(provider_key: key, auth_type: "subscription")
  end

  def self.first_enabled_for_owner(owner)
    return unless owner

    executable_keys = ProviderSupport.container_executable_provider_keys
    owner.providers.for_agent_runs.where(provider_key: executable_keys).ordered.first
  end

  def self.display_name_for(provider_key)
    return "Unknown" if provider_key.blank?

    provider = AgentHarness.provider(ProviderSupport.harness_provider_key_for(provider_key).to_sym)

    if provider.respond_to?(:display_name)
      provider.display_name
    else
      provider_key.to_s.titleize
    end
  rescue AgentHarness::ConfigurationError
    provider_key.to_s.titleize
  end

  def self.display_name(provider_key)
    display_name_for(provider_key)
  end

  def self.supported_provider_keys
    ProviderSupport.supported_provider_keys
  end

  def self.supported_provider_key?(provider_key)
    ProviderSupport.supported_provider_key?(provider_key)
  end

  def self.addable_provider_keys
    ProviderSupport.addable_provider_keys
  end

  def self.addable_provider_key?(provider_key)
    ProviderSupport.addable_provider_key?(provider_key)
  end

  def self.harness_provider_key_for(provider_key)
    ProviderSupport.harness_provider_key_for(provider_key)
  end

  def self.provider_key_for_agent_type(agent_type)
    ProviderSupport.provider_key_for_agent_type(agent_type)
  end

  def self.agent_type_for(provider_key)
    ProviderSupport.agent_type_for(provider_key)
  end

  def self.api_service_type_for(provider_key)
    ProviderSupport.api_service_type_for(provider_key)
  end

  def self.routing_key?(identifier)
    identifier.to_s.start_with?(ROUTING_KEY_PREFIX)
  end

  def self.id_from_routing_key(identifier)
    return unless routing_key?(identifier)

    id_str = identifier.to_s.delete_prefix(ROUTING_KEY_PREFIX)
    id = Integer(id_str, exception: false)
    return unless id&.positive?

    id
  end

  def self.for_identifier(user, identifier)
    return nil unless user
    return nil if identifier.blank?

    if routing_key?(identifier)
      user.providers.find_by(id: id_from_routing_key(identifier))
    else
      matching_providers = user.providers.where(provider_key: identifier).ordered
      matching_providers.subscription.first || matching_providers.first
    end
  end

  # Updates the enabled_for_fallback flag on each of the user's providers
  # based on the given set of enabled provider identifiers.
  def self.update_fallback_flags(user, enabled_keys)
    user.providers.transaction do
      user.providers.find_each do |provider|
        new_value = enabled_keys.any? { |identifier| provider.matches_identifier?(identifier) }
        next if provider.enabled_for_fallback? == new_value

        unless provider.update(enabled_for_fallback: new_value)
          raise ActiveRecord::Rollback
        end
      end
    end
  end

  private

  def sync_direct_outbound_tier_models
    return unless direct_outbound_model_id.present?
    return unless requires_direct_outbound?
    return unless will_save_change_to_config? || tier_model_ids.blank?

    model = ensure_direct_outbound_llm_model!
    self.tier_model_ids = LlmModel::TIERS.each_with_object({}) { |t, h| h[t] = model.model_id }
  end

  def direct_outbound_display_name(model_id)
    base = model_id.include?("/") ? model_id.split("/").last : model_id
    base.tr("_-", " ").split.map(&:capitalize).join(" ")
  end

  def normalize_agent_co_author_trailer
    stripped = agent_co_author_trailer.to_s.strip
    self.agent_co_author_trailer = stripped.present? ? stripped : nil
  end

  def agent_co_author_trailer_is_single_line
    return if agent_co_author_trailer.blank?
    return unless agent_co_author_trailer.match?(/[\r\n]/)

    errors.add(:agent_co_author_trailer, "must be a single line (no newlines)")
  end

  def must_keep_at_least_one_agent_run_provider
    return unless user
    return unless will_save_change_to_enabled_for_agent_runs?(from: true, to: false)
    return if user.providers.where.not(id: id).for_agent_runs.exists?

    errors.add(:enabled_for_agent_runs, "must keep at least one provider enabled for agent runs")
  end

  def prevent_destroying_last_agent_run_provider
    return if destroyed_by_association.present?
    return unless enabled_for_agent_runs?
    return if user.providers.where.not(id: id).for_agent_runs.exists?

    errors.add(:base, "Cannot delete the last provider enabled for agent runs")
    throw(:abort)
  end

  def default_provider_must_remain_enabled_for_agent_runs
    default_key = self.class.default_provider_key
    return unless default_key
    return unless provider_key == default_key && subscription?
    return unless will_save_change_to_enabled_for_agent_runs?(to: false)

    errors.add(:enabled_for_agent_runs,
      "#{Provider.display_name(default_key)} must remain enabled for agent runs")
  end

  def prevent_destroying_default_provider
    default_key = self.class.default_provider_key
    return if destroyed_by_association.present?
    return unless default_key
    return unless provider_key == default_key && subscription?

    errors.add(:base, "Cannot delete the #{Provider.display_name(default_key)} provider")
    throw(:abort)
  end

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
      errors.add(:provider_api_key, "is not supported for this provider; use subscription authentication instead")
      return
    end

    return if provider_api_key.api_service_type == required_service

    errors.add(:provider_api_key, "must be an API key for #{ProviderSupport.api_service_type_label(required_service)}")
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

    errors.add(:fallback_role, "must be standard for subscription providers")
  end

  def api_key_entry_must_be_unique
    return unless api_key?
    return unless user

    normalized_name = name.to_s
    duplicate = user.providers.api_key.where(
      provider_key: provider_key,
      provider_api_key_id: provider_api_key_id
    ).where.not(id: id).where("COALESCE(name, '') = ?", normalized_name).exists?
    return unless duplicate

    errors.add(:provider_key, "already has an entry with this API key")
  end

  def opencode_api_key_config_must_be_valid
    return unless provider_key == "opencode"
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

    expected_provider = Providers::DefaultTierModelIds::PROVIDER_KEY_TO_MODEL_PROVIDER[provider_key.to_s]
    if expected_provider.nil? && !requires_direct_outbound?
      errors.add(:tier_model_ids, "is not configurable for provider #{provider_key}")
      return
    end

    tier_model_ids.each do |tier, model_id|
      next if model_id.blank?

      model = LlmModel.find_by(model_id: model_id)
      if model.nil?
        errors.add(:tier_model_ids, "references unknown model #{model_id} for tier #{tier}")
      elsif expected_provider && !requires_direct_outbound? && model.provider != expected_provider
        errors.add(:tier_model_ids, "model #{model_id} does not belong to provider #{provider_key}")
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
    return unless provider_key == "kilocode"
    return unless api_key?

    unless KILOCODE_API_PROVIDER_KEYS.include?(kilocode_api_provider)
      errors.add(:config, "must include a supported KiloCode API provider")
    end

    if kilocode_model_id.blank?
      errors.add(:config, "must include a KiloCode model id")
    end
  end

  # NOTE: The provider UI/controller does not yet permit nested aider config
  # keys (api_provider, model). This validation is prep work for when the
  # controller is updated to support Aider API-key providers.
  def aider_api_key_config_must_be_valid
    return unless provider_key == "aider"
    return unless api_key?

    unless AIDER_API_PROVIDER_KEYS.include?(aider_api_provider)
      errors.add(:config, "must include a supported Aider API provider")
    end

    if aider_model_id.blank?
      errors.add(:config, "must include an Aider model id")
    end
  end

  def required_api_service_type
    return opencode_required_api_service_type if provider_key == "opencode"
    return kilocode_required_api_service_type if provider_key == "kilocode"
    return aider_required_api_service_type if provider_key == "aider"

    self.class.api_service_type_for(provider_key)
  end

  def opencode_direct_outbound?
    provider_key == "opencode" &&
      api_key? &&
      OPENCODE_API_PROVIDER_KEYS.include?(opencode_api_provider) &&
      opencode_model_id.present?
  end

  def kilocode_direct_outbound?
    provider_key == "kilocode" &&
      api_key? &&
      KILOCODE_API_PROVIDER_KEYS.include?(kilocode_api_provider) &&
      kilocode_model_id.present?
  end

  def aider_direct_outbound?
    provider_key == "aider" &&
      api_key? &&
      AIDER_API_PROVIDER_KEYS.include?(aider_api_provider) &&
      aider_model_id.present?
  end

  def opencode_provider_runtime
    model_id = opencode_qualified_model
    raise ArgumentError, "Missing OpenCode model id for provider #{id || provider_key}" if model_id.blank?

    api_config = DIRECT_OUTBOUND_API_PROVIDERS.fetch(opencode_api_provider, DIRECT_OUTBOUND_API_PROVIDERS["openrouter"])

    env_var = "#{api_config[:service_type].upcase.tr('-', '_')}_API_KEY"
    env = { env_var => provider_api_key&.api_key.to_s }
    env["OPENAI_BASE_URL"] = api_config[:base_url] if api_config[:base_url]

    AgentHarness::ProviderRuntime.new(
      model: model_id,
      env: env,
      unset_env: %w[OPENAI_HEADER_X_AGENT_RUN_ID OPENAI_HEADER_X_PROXY_TOKEN],
      metadata: {
        config: {
          "provider" => { opencode_api_provider => {} }
        }
      }
    )
  end
end
