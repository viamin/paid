# frozen_string_literal: true

module OutputSanitizer
  # Normalizes command and provider output into scrubbed UTF-8 text for logging,
  # truncation, and error classification.
  def normalize_output_text(text)
    return "" if text.nil?

    normalized_text = text.to_s
    return normalized_text.delete("\u0000") if normalized_text.encoding == Encoding::UTF_8 && normalized_text.valid_encoding?

    normalized_text
      .dup
      .force_encoding(Encoding::UTF_8)
      .scrub
      .delete("\u0000")
  end
end
