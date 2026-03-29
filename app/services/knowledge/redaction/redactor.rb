# frozen_string_literal: true

module Knowledge
  module Redaction
    class Redactor
      FULLY_REDACTED_THRESHOLD = 0.6

      Result = Data.define(:clean_text, :redactions, :original_length) do
        def fully_redacted?
          return true if original_length.zero?

          redacted_chars = redactions.sum(&:length)
          redacted_chars.to_f / original_length >= FULLY_REDACTED_THRESHOLD
        end

        def redacted?
          redactions.any?
        end
      end

      def self.call(text:)
        new.call(text: text)
      end

      def call(text:)
        text = text.to_s
        matches = Scanner.scan(text)

        if matches.empty?
          return Result.new(clean_text: text, redactions: matches, original_length: text.length)
        end

        clean = build_clean_text(text, matches)
        Result.new(clean_text: clean, redactions: matches, original_length: text.length)
      end

      private

      def build_clean_text(text, matches)
        merged = merge_overlapping(matches)
        result = +""
        last_end = 0

        merged.each do |m|
          result << text[last_end...m.offset] if m.offset > last_end
          result << "[REDACTED:#{m.pattern}]"
          last_end = m.offset + m.length
        end

        result << text[last_end..] if last_end < text.length
        result
      end

      def merge_overlapping(matches)
        sorted = matches.sort_by(&:offset)
        merged = []

        sorted.each do |m|
          if merged.empty? || m.offset > merged.last.offset + merged.last.length
            merged << m
          else
            prev = merged.last
            new_end = [ prev.offset + prev.length, m.offset + m.length ].max
            merged[-1] = Scanner::Match.new(
              pattern: prev.pattern,
              offset: prev.offset,
              length: new_end - prev.offset
            )
          end
        end

        merged
      end
    end
  end
end
