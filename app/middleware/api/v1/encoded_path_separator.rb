# frozen_string_literal: true

module Api
  module V1
    # Committee validates the raw Rack path while Rails decodes route
    # parameters. Normalize the inbox entry separator before Committee sees it
    # so its OpenAPI pattern describes the identifier Rails receives.
    class EncodedPathSeparator
      INBOX_ENTRY_PATH = %r{\A/api/v1/inbox/entries/}

      # @spec MOBILE-API-008 MOBILE-API-016 MOBILE-API-018
      def initialize(app)
        @app = app
      end

      def call(env)
        normalize_inbox_entry_separator!(env)
        @app.call(env)
      end

      private

      def normalize_inbox_entry_separator!(env)
        path = env.fetch("PATH_INFO")
        return unless path.match?(INBOX_ENTRY_PATH)

        env["PATH_INFO"] = path.gsub(/%3a/i, ":")
      end
    end
  end
end
