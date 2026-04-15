# frozen_string_literal: true

module Knowledge
  class ProviderSelector
    def self.for_embedding(user_setting:)
      new(user_setting:).providers_for(:embedding)
    end

    def self.for_chat(user_setting:)
      new(user_setting:).providers_for(:chat)
    end

    def initialize(user_setting:)
      @user_setting = user_setting
    end

    def providers_for(operation)
      candidates = configured_providers_for(operation)
      warn_on_embedding_fallback(candidates) if operation.to_sym == :embedding

      provider_states = user_setting.user.provider_states.where(provider_name: candidates).index_by(&:provider_name)

      candidates.select do |provider|
        provider_available?(provider, provider_states)
      end
    end

    private

    attr_reader :user_setting

    def configured_providers_for(operation)
      providers = configured_provider_values_for(operation).filter_map do |provider|
        provider.to_s.strip.downcase.presence
      end.uniq

      filter_supported_providers(providers, operation: operation)
    end

    def configured_provider_values_for(operation)
      case operation.to_sym
      when :embedding
        [ user_setting.kb_embedding_provider, *Array(user_setting.kb_embedding_fallback_providers) ]
      when :chat
        [ user_setting.kb_chat_provider, *Array(user_setting.kb_chat_fallback_providers) ]
      else
        raise ArgumentError, "Unsupported knowledge provider operation: #{operation}"
      end
    end

    def filter_supported_providers(providers, operation:)
      supported = supported_providers_for(operation)
      unsupported = providers - supported
      log_unsupported_providers(operation, unsupported) if unsupported.any?

      providers - unsupported
    end

    def supported_providers_for(operation)
      case operation.to_sym
      when :embedding
        UserSetting::KB_EMBEDDING_PROVIDERS
      when :chat
        UserSetting::KB_CHAT_PROVIDERS
      else
        raise ArgumentError, "Unsupported knowledge provider operation: #{operation}"
      end
    end

    def provider_available?(provider, provider_states)
      state = provider_states[provider]
      return true unless state

      state.check_circuit_recovery!(timeout: user_setting.circuit_breaker_timeout_seconds)
      !state.unavailable?
    end

    # Embedding fallback must stay on a provider that serves the same model and
    # dimensions as the primary embedding provider. Cross-model fallback would
    # require re-embedding all chunks and rebuilding the Qdrant collection.
    def warn_on_embedding_fallback(candidates)
      return unless candidates.size > 1

      Rails.logger.warn(
        message: "knowledge.provider_selector.embedding_fallback_requires_compatible_model",
        user_setting_id: user_setting.id,
        providers: candidates,
        model: Knowledge::Embeddings::Generate::MODEL,
        dimensions: Knowledge::Embeddings::Generate::DIMENSIONS
      )
    end

    def log_unsupported_providers(operation, providers)
      Rails.logger.warn(
        message: "knowledge.provider_selector.unsupported_provider_configured",
        user_setting_id: user_setting.id,
        operation: operation.to_sym,
        providers: providers
      )
    end
  end
end
