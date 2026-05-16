# frozen_string_literal: true

class Provider < Runner
  after_validation :bridge_runner_validation_errors

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

  private

  def bridge_runner_validation_errors
    mirror_runner_key_errors_to_provider_key
    mirror_provider_wording_for_api_key_support
  end

  def mirror_runner_key_errors_to_provider_key
    return if errors[:runner_key].blank?

    errors[:runner_key].each do |message|
      errors.add(:provider_key, message) unless errors[:provider_key].include?(message)
    end
  end

  def mirror_provider_wording_for_api_key_support
    runner_message = "is not supported for this runner; use subscription authentication instead"
    provider_message = "is not supported for this provider; use subscription authentication instead"
    return unless errors[:provider_api_key].include?(runner_message)
    return if errors[:provider_api_key].include?(provider_message)

    errors.add(:provider_api_key, provider_message)
  end
end
