# frozen_string_literal: true

module Integrations
  class LinearProvider < Provider
    class << self
      def key = :linear

      def provider_name = "Linear"

      def category = :issue_tracking

      def icon_svg
        '<svg class="h-6 w-6" fill="currentColor" viewBox="0 0 24 24" aria-hidden="true">' \
          '<path d="M2.513 12.833l8.654 8.654a9.952 9.952 0 01-3.62-1.757l-5.034-5.034a' \
          "9.953 9.953 0 01-1.757-3.62L2.513 12.833zm-.756-3.22a9.953 9.953 0 01.614-1.36" \
          "L9.207 15.09a9.952 9.952 0 01-1.36.614L1.757 9.613zm-.614 5.666l9.578 9.578a" \
          "10.07 10.07 0 01-1.794-.524L1.281 16.69a10.074 10.074 0 01-.524-1.794zm1.857-" \
          "8.154l11.875 11.875a9.952 9.952 0 01-1.463.914L2.086 8.588a9.952 9.952 0 01" \
          ".914-1.463zm2.005-2.004a10.04 10.04 0 011.462-.915l11.326 11.326a10.04 10.04 " \
          "0 01-.914 1.462L5.005 5.121zm3.025-1.7l11.549 11.549a9.953 9.953 0 01-1.36.614" \
          "L6.67 4.035a9.952 9.952 0 011.36-.614zm3.32-1.156l8.654 8.654a9.952 9.952 0 " \
          "01-1.757-3.62L13.213 3.16a9.953 9.953 0 01-3.62-1.757L11.35 2.265zm2.138-.618" \
          "l9.578 9.578a10.074 10.074 0 01-.524-1.794L14.898 1.787a10.07 10.07 0 01-1.794" \
          "-.524zm3.559 1.2l7.686 7.686a9.993 9.993 0 00-7.686-7.686zm3.326 3.327l4.3 4.3" \
          'a9.994 9.994 0 00-4.3-4.3z" />' \
          "</svg>"
      end

      def model_class = LinearToken

      def new_path
        Rails.application.routes.url_helpers.new_linear_token_path
      end

      def index_path
        Rails.application.routes.url_helpers.linear_tokens_path
      end

      def description
        "Connect Linear for issue tracking integration — sync issues and project updates."
      end

      def available?
        true
      end
    end
  end
end
