# frozen_string_literal: true

module AgentHarness
  module Providers
    class AzureOpenai < OpenaiCompatible
      DEFAULT_BASE_URL = "https://example-resource.openai.azure.com"
      API_KEY_ENV_VAR = "AZURE_OPENAI_API_KEY"
      DEFAULT_API_VERSION = "2024-10-21"

      class << self
        def provider_name
          :azure_openai
        end
      end

      private

      def embeddings_path(model:, runtime:)
        deployment = runtime&.metadata&.fetch(:deployment, nil) ||
          runtime&.metadata&.fetch("deployment", nil) ||
          @config.deployment || model
        api_version = runtime&.metadata&.fetch(:api_version, nil) ||
          runtime&.metadata&.fetch("api_version", nil) ||
          @config.api_version || DEFAULT_API_VERSION

        "/openai/deployments/#{deployment}/embeddings?api-version=#{api_version}"
      end

      def build_headers(runtime:)
        headers = super
        headers.delete("Authorization")
        headers["api-key"] = api_key(runtime)
        headers
      end

      def embedding_payload(texts:, model:, dimensions:)
        payload = {input: texts}
        payload[:dimensions] = dimensions if dimensions
        payload
      end
    end
  end
end
