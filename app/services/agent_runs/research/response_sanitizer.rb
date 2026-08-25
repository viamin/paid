# frozen_string_literal: true

module AgentRuns
  module Research
    class ResponseSanitizer
      API_KEY_SHAPES = [
        /\bsk_(?:live|test)_[A-Za-z0-9]{20,}\b/
      ].freeze

      Result = Data.define(:content, :redacted, :quarantined, :tokens_estimate, :preview)

      def self.call(...)
        new.call(...)
      end

      def call(body:, content_type:)
        text = extract_text(body: body, content_type: content_type)
        normalized = normalize_api_key_shapes(text)
        redaction = Knowledge::Redaction::Redactor.call(text: normalized)
        content = redaction.fully_redacted? ? quarantined_message(redaction.clean_text) : redaction.clean_text
        manually_redacted = normalized != text

        Result.new(
          content: PromptAssembly::Section.quarantine(content),
          redacted: manually_redacted || redaction.redacted?,
          quarantined: manually_redacted || redaction.fully_redacted?,
          tokens_estimate: estimate_tokens(redaction.clean_text),
          preview: redaction.clean_text.truncate(500)
        )
      end

      private

      def extract_text(body:, content_type:)
        return "" if body.blank?
        return body.to_s unless content_type == "text/html"

        document = Nokogiri::HTML(body.to_s)
        document.css("script,style,noscript").remove
        document.text.gsub(/\s+/, " ").strip
      end

      def quarantined_message(redacted_text)
        message = "Response quarantined because credential-like content was detected."
        return message if redacted_text.blank?

        "#{message}\n\n#{redacted_text.truncate(1000)}"
      end

      def estimate_tokens(text)
        [ (text.to_s.length / 4.0).ceil, 0 ].max
      end

      def normalize_api_key_shapes(text)
        API_KEY_SHAPES.reduce(text.to_s) do |memo, pattern|
          memo.gsub(pattern, "[REDACTED:api_key]")
        end
      end
    end
  end
end
