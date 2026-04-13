# frozen_string_literal: true

module AgentHarness
  module Providers
    class Openrouter < OpenaiCompatible
      DEFAULT_BASE_URL = "https://openrouter.ai/api/v1"
      API_KEY_ENV_VAR = "OPENROUTER_API_KEY"

      class << self
        def provider_name
          :openrouter
        end
      end

      private

      def embeddings_path(model:, runtime:)
        "/embeddings"
      end
    end
  end
end
