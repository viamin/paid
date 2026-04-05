# frozen_string_literal: true

module OutputSanitizer
  def normalize_output_text(text)
    normalized_text = text.to_s
    return normalized_text.delete("\u0000") if normalized_text.encoding == Encoding::UTF_8 && normalized_text.valid_encoding?

    normalized_text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\uFFFD").delete("\u0000")
  end
end
