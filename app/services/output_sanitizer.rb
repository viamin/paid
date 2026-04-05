# frozen_string_literal: true

module OutputSanitizer
  def normalize_output_text(text)
    normalized_text = text.to_s
    return normalized_text.delete("\u0000") if normalized_text.encoding == Encoding::UTF_8 && normalized_text.valid_encoding?

    normalized_text
      .dup
      .force_encoding(Encoding::UTF_8)
      .scrub
      .delete("\u0000")
  end
end
