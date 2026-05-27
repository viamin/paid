# frozen_string_literal: true

class Provider < Runner
  after_validation :bridge_runner_validation_errors

  PI_API_PROVIDERS = Runner::PI_API_PROVIDERS
  PI_API_PROVIDER_KEYS = Runner::PI_API_PROVIDER_KEYS
  PI_DEFAULT_API_PROVIDER = Runner::PI_DEFAULT_API_PROVIDER

  class << self
    def display_name_for(provider_key)
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

    def display_name(provider_key)
      display_name_for(provider_key)
    end

    def supported_provider_keys
      ProviderSupport.supported_provider_keys
    end

    def supported_provider_key?(provider_key)
      ProviderSupport.supported_provider_key?(provider_key)
    end

    def addable_provider_keys
      ProviderSupport.addable_provider_keys
    end

    def addable_provider_key?(provider_key)
      ProviderSupport.addable_provider_key?(provider_key)
    end

    def default_provider_key
      default_runner_key
    end

    def harness_provider_key_for(provider_key)
      ProviderSupport.harness_provider_key_for(provider_key)
    end

    def provider_key_for_agent_type(agent_type)
      ProviderSupport.provider_key_for_agent_type(agent_type)
    end

    def agent_type_for(provider_key)
      ProviderSupport.agent_type_for(provider_key)
    end

    def api_service_type_for(provider_key)
      ProviderSupport.api_service_type_for(provider_key)
    end
  end

  def agent_harness_provider_runtime
    agent_harness_runner_runtime
  end

  def agent_harness_runtime?
    super
  end

  def provider_key
    self[:provider_key].presence || runner_key
  end

  def provider_key=(value)
    self[:provider_key] = value
    self.runner_key = value
  end

  def pi_api_provider
    return nil unless provider_key == "pi"

    super
  end

  def pi_model_id
    return nil unless provider_key == "pi"

    super
  end

  def tier_model_picker_visible_on_provider?
    Providers::DefaultTierModelIds::PROVIDER_KEY_TO_MODEL_PROVIDER.key?(provider_key.to_s)
  end

  def tier_model_picker_provider
    if tier_model_picker_visible_on_runner?
      direct_outbound_llm_model_provider
    elsif tier_model_picker_visible_on_provider?
      Providers::DefaultTierModelIds::PROVIDER_KEY_TO_MODEL_PROVIDER[provider_key.to_s]
    end
  end

  private

  def must_keep_at_least_one_agent_run_runner
    super
    replace_error_message(
      :enabled_for_agent_runs,
      "must keep at least one runner enabled for agent runs",
      "must keep at least one provider enabled for agent runs"
    )
  end

  def subscription_must_have_standard_fallback_role
    super
    replace_error_message(
      :fallback_role,
      "must be standard for subscription runners",
      "must be standard for subscription providers"
    )
  end

  def prevent_destroying_last_agent_run_runner
    return if destroyed_by_association.present?
    return unless enabled_for_agent_runs?
    return if user.providers.kept_only.where.not(id: id).for_agent_runs.exists?

    errors.add(:base, "Cannot delete the last provider enabled for agent runs")
    throw(:abort)
  end

  def bridge_runner_validation_errors
    mirror_runner_key_errors_to_provider_key
    mirror_provider_wording(
      attribute: :provider_api_key,
      runner_message: "is not supported for this runner; use subscription authentication instead",
      provider_message: "is not supported for this provider; use subscription authentication instead"
    )
    mirror_provider_wording(
      attribute: :enabled_for_agent_runs,
      runner_message: "must keep at least one runner enabled for agent runs",
      provider_message: "must keep at least one provider enabled for agent runs"
    )
    mirror_provider_wording(
      attribute: :fallback_role,
      runner_message: "must be standard for subscription runners",
      provider_message: "must be standard for subscription providers"
    )
    mirror_provider_wording(
      attribute: :base,
      runner_message: "Cannot delete the last runner enabled for agent runs",
      provider_message: "Cannot delete the last provider enabled for agent runs"
    )
  end

  def mirror_runner_key_errors_to_provider_key
    return if errors[:runner_key].blank?

    errors[:runner_key].each do |message|
      errors.add(:provider_key, message) unless errors[:provider_key].include?(message)
    end
  end

  def mirror_provider_wording(attribute:, runner_message:, provider_message:)
    return unless errors[attribute].include?(runner_message)
    return if errors[attribute].include?(provider_message)

    errors.add(attribute, provider_message)
  end

  def replace_error_message(attribute, runner_message, provider_message)
    return unless errors[attribute].include?(runner_message)

    errors.delete(attribute, runner_message)
    errors.add(attribute, provider_message) unless errors[attribute].include?(provider_message)
  end

  def direct_outbound_api_key_env_var(api_provider)
    api_config = DIRECT_OUTBOUND_API_PROVIDERS[api_provider.to_s]
    return "OPENAI_API_KEY" if api_config.blank?

    api_config[:env_var].presence || "#{api_config[:service_type].upcase.tr('-', '_')}_API_KEY"
  end
end
