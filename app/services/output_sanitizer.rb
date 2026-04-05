module OutputSanitizer
  def normalize_output_text(text)
    normalized_text = text.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\uFFFD")
    normalized_text.delete("\u0000")
  end
end
