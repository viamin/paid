# frozen_string_literal: true

module ChatSessions
  # Builds the durable notice shown when an unattended retry exhausts every
  # runner with a non-rate-limit provider error. These errors are deliberately
  # not scheduled as rate-limit retries because they can require intervention.
  class ProviderErrorNotice
    Result = Data.define(:content, :metadata)

    def self.build(error:)
      new(error:).build
    end

    def initialize(error:)
      @error = error
    end

    def build
      # @spec CHAT-API-017
      Result.new(content: content, metadata: { "provider_error_notice" => true })
    end

    private

    attr_reader :error

    def content
      "Chat could not resume: #{ChatSessions::ErrorMessage.for(error)}. " \
        "Check the runner configuration and send your message again."
    end
  end
end
