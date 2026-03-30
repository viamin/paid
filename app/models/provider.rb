# frozen_string_literal: true

class Provider < ApplicationRecord
  AUTH_TYPES = %w[subscription api_key].freeze
  FALLBACK_ROLES = %w[standard rate_limit_fallback].freeze
  ROUTING_KEY_PREFIX = "provider:".freeze
  OPENCODE_API_PROVIDER_KEYS = %w[openrouter].freeze
  OPENCODE_DEFAULT_API_PROVIDER = "openrouter"
  OPENCODE_DEFAULT_BASE_URL = "https://openrouter.ai/api/v1".freeze

  belongs_to :user
  belongs_to :provider_api_key, optional: true

  scope :for_agent_runs, -> { where(enabled_for_agent_runs: true) }
  scope :for_fallback, -> { where(enabled_for_fallback: true) }
  scope :ordered, -> { order(:provider_key, :auth_type, :name, :id) }
  scope :subscription, -> { where(auth_type: "subscription") }
  scope :api_key, -> { where(auth_type: "api_key") }
  scope :rate_limit_fallback, -> { where(fallback_role: "rate_limit_fallback") }

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
  validate :api_key_must_belong_to_same_user
  validate :subscription_must_have_standard_fallback_role
  validate :api_key_entry_must_be_unique
  validate :opencode_api_key_config_must_be_valid

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

    label = provider_key.titleize
    if provider_key == "opencode" && opencode_model_id.present?
      label += " #{opencode_model_id}"
    end
    label += " (API Key)" if api_key?
    label
  end

  def routing_key
    persisted? ? "#{ROUTING_KEY_PREFIX}#{id}" : provider_key.to_s
  end

  def matches_identifier?(identifier)
    identifier.to_s == routing_key || identifier.to_s == provider_key.to_s
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

  def requires_direct_outbound?
    provider_key == "opencode" &&
      api_key? &&
      opencode_api_provider == "openrouter" &&
      opencode_model_id.present?
  end

  def opencode_config_json
    provider_id = "paid-provider-#{id || provider_key}"
    model_id = opencode_model_id
    raise ArgumentError, "Missing OpenCode model id for provider #{id || provider_key}" if model_id.blank?

    JSON.pretty_generate(
      {
        "$schema" => "https://opencode.ai/config.json",
        "provider" => {
          provider_id => {
            "npm" => "@ai-sdk/openai-compatible",
            "name" => display_name,
            "options" => {
              "baseURL" => OPENCODE_DEFAULT_BASE_URL,
              "apiKey" => provider_api_key&.api_key.to_s
            },
            "models" => {
              model_id => {
                "name" => model_id
              }
            }
          }
        },
        "model" => "#{provider_id}/#{model_id}"
      }
    )
  end

  def direct_outbound_exec_env
    return {} unless requires_direct_outbound?

    { "PAID_OPENCODE_CONFIG_B64" => Base64.strict_encode64(opencode_config_json) }
  end

  def direct_outbound_exec_command(command_prefix:, prompt:)
    return command_prefix + [ prompt ] unless requires_direct_outbound?

    command = "#{command_prefix.shelljoin} \"$1\""
    script = <<~SH.squish
      mkdir -p /home/agent/.config/opencode &&
      printf '%s' "$PAID_OPENCODE_CONFIG_B64" | base64 -d > /home/agent/.config/opencode/opencode.json &&
      #{command}
    SH
    [ "sh", "-lc", script, "--", prompt ]
  end

  # Returns the provider key that must always exist and remain enabled for
  # agent runs. Prefers "claude" when container-executable, otherwise falls
  # back to the first available container-executable provider. Returns nil
  # when no container-executable providers are available, so callers can
  # surface a user-facing error instead of a 500.
  def self.default_provider_key
    executable_keys = ProviderSupport.container_executable_provider_keys
    executable_keys.include?("claude") ? "claude" : executable_keys.first
  end

  def self.ensure_default_for(user)
    key = default_provider_key
    return unless key

    user.providers.find_or_create_by!(provider_key: key, auth_type: "subscription")
  rescue ActiveRecord::RecordNotUnique
    user.providers.find_by!(provider_key: key, auth_type: "subscription")
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

  def self.compatibility_label_for(target)
    return "OpenRouter" if target.to_s == "openrouter"

    target.to_s
  end

  def self.required_api_key_targets_for(provider_key:, config: nil)
    return [ OPENCODE_DEFAULT_API_PROVIDER ] if provider_key.to_s == "opencode"

    [ provider_key.to_s ]
  end

  def self.routing_key?(identifier)
    identifier.to_s.start_with?(ROUTING_KEY_PREFIX)
  end

  def self.id_from_routing_key(identifier)
    return unless routing_key?(identifier)

    identifier.to_s.delete_prefix(ROUTING_KEY_PREFIX).to_i
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

    targets = self.class.required_api_key_targets_for(provider_key: provider_key, config: config)
    return if targets.any? { |target| provider_api_key.compatible_with?(target) }

    errors.add(:provider_api_key, "is not compatible with #{self.class.compatibility_label_for(targets.first)}")
  end

  def api_key_must_belong_to_same_user
    return unless api_key?
    return if provider_api_key_id.blank?
    return unless provider_api_key
    return if provider_api_key.user_id == user_id

    errors.add(:provider_api_key, "must belong to the same user")
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

    return if opencode_model_id.present?

    errors.add(:config, "must include an OpenCode model ID")
  end
end
