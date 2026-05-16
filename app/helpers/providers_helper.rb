# frozen_string_literal: true

module ProvidersHelper
  include RunnersHelper

  def provider_auth_instruction_blocks
    ProviderSupport.supported_provider_keys.map { |provider_key| provider_auth_instruction_block(provider_key) }
  end

  private

  def provider_auth_instruction_block(provider_key)
    copy = RunnersHelper::RUNNER_AUTH_INSTRUCTION_COPY[provider_key]
    return copy.merge(provider_key: provider_key, title: Provider.display_name(provider_key), fallback: false) if copy

    {
      provider_key: provider_key,
      title: Provider.display_name(provider_key),
      summary: "Use the auth mode configured on the provider entry:",
      items: [
        "Subscription entries rely on the provider CLI's local login state being visible inside the agent container.",
        "API-key entries rely on a compatible Paid Provider API Key or proxy-backed service configuration.",
        "Provider-specific setup notes are not available yet, so this generic checklist is shown instead of hiding the provider."
      ],
      fallback: true
    }
  end
end
