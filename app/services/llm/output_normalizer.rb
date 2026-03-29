# frozen_string_literal: true

module Llm
  # Shared helpers for cleaning LLM output. LLMs sometimes wrap responses in
  # markdown fences or quote characters despite being told not to. Both
  # GenerateIssueTitle and GeneratePrDescription use these normalizations.
  module OutputNormalizer
    # Common quote pairs that LLMs wrap output in, ordered by likelihood.
    QUOTE_PAIRS = [
      [ '"', '"' ],           # ASCII double quotes
      [ "'", "'" ],           # ASCII single quotes
      [ "`", "`" ],           # Backticks
      [ "\u201C", "\u201D" ], # Curly double quotes (left/right)
      [ "\u2018", "\u2019" ]  # Curly single quotes (left/right)
    ].freeze

    # Strips a single pair of surrounding quotes from text.
    # Returns the cleaned string (may be the original if no quotes matched).
    def strip_surrounding_quotes(text)
      QUOTE_PAIRS.each do |left, right|
        if text.start_with?(left) && text.end_with?(right) && text.length >= left.length + right.length
          return text[left.length..-(right.length + 1)].strip
        end
      end

      text
    end

    # Strips a single outer markdown code fence (```...```) if present.
    def strip_markdown_fence(text)
      lines = text.lines
      if lines.size >= 2 && lines.first.match?(/\A```/) && lines.last.strip == "```"
        return (lines[1...-1] || []).join.strip
      end

      text
    end
  end
end
