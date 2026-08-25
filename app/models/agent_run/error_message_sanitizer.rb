# frozen_string_literal: true

class AgentRun
  # Canonical sanitization pipeline for error message text surfaced to users
  # or agents (runner attempt errors, auto-merge diagnostics): normalize
  # encoding, strip secret shapes, and truncate to the shared cap. All call
  # sites go through this class so the redaction pipeline lives in one place.
  class ErrorMessageSanitizer
    def self.call(text:)
      return nil if text.blank?

      normalized = normalize_encoding(text.to_s)
      redacted = Knowledge::Redaction::Redactor.call(text: normalized).clean_text
      redacted = redact_secrets(redacted)
      redacted.truncate(MAX_RUNNER_ATTEMPT_ERROR_MESSAGE_LENGTH)
    end

    # Normalizes external text to valid UTF-8 and strips NUL bytes so invalid
    # byte sequences fail here instead of deep in display/persistence layers.
    def self.normalize_encoding(text)
      return text.delete("\x00") if text.encoding == Encoding::UTF_8 && text.valid_encoding?

      text.dup.force_encoding(Encoding::UTF_8).scrub.delete("\x00")
    end

    def self.redact_secrets(text)
      RUNNER_ATTEMPT_SECRET_PATTERNS.reduce(text) do |result, (pattern, replacement)|
        result.gsub(pattern, replacement)
      end
    end
  end
end
