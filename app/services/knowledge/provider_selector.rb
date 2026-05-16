# frozen_string_literal: true

module Knowledge
  class ProviderSelector < RunnerSelector
    private

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

    def log_unsupported_runners(operation, runners)
      Rails.logger.warn(
        message: "knowledge.provider_selector.unsupported_provider_configured",
        user_setting_id: user_setting.id,
        operation: operation.to_sym,
        providers: runners
      )
    end
  end
end
