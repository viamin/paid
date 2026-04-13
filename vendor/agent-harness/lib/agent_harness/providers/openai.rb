# frozen_string_literal: true

module AgentHarness
  module Providers
    class Openai < OpenaiCompatible
      DEFAULT_BASE_URL = "https://api.openai.com"
      API_KEY_ENV_VAR = "OPENAI_API_KEY"

      class << self
        def provider_name
          :openai
        end
      end
    end
  end
end
