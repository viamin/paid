# frozen_string_literal: true

module Ci
  # Reduces CI logs to prompt-sized failure context.
  class LogExtractor
    DEFAULT_MAX_CHARS = 8_000
    SMALL_LOG_CHARS = 10_000
    CONTEXT_BEFORE = 2
    CONTEXT_AFTER = 3
    ERROR_PATTERN = /\b(error|fail(?:ed|ure|ing)?|exception|assert(?:ion)?|fatal|traceback)\b/i

    def self.call(log_text, max_chars: DEFAULT_MAX_CHARS)
      new(log_text, max_chars: max_chars).extract
    end

    def initialize(log_text, max_chars:)
      @log_text = log_text.to_s
      @max_chars = max_chars
    end

    def extract
      text = normalized_log
      return "" if text.blank?
      return truncate(text) if text.length <= SMALL_LOG_CHARS

      truncate(extract_matching_context(text))
    end

    private

    attr_reader :log_text, :max_chars

    def normalized_log
      log_text.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
    end

    def extract_matching_context(text)
      lines = text.lines
      ranges = matching_line_indexes(lines).map do |index|
        ([ index - CONTEXT_BEFORE, 0 ].max)..([ index + CONTEXT_AFTER, lines.length - 1 ].min)
      end

      merge_ranges(ranges).map { |range| lines[range].join }.join("\n--\n")
    end

    def matching_line_indexes(lines)
      lines.each_index.select { |index| lines[index].match?(ERROR_PATTERN) }
    end

    def merge_ranges(ranges)
      ranges.each_with_object([]) do |range, merged|
        if merged.last&.cover?(range.first - 1)
          merged[-1] = merged.last.first..[ merged.last.last, range.last ].max
        else
          merged << range
        end
      end
    end

    def truncate(text)
      return text if text.length <= max_chars

      "#{text[0, max_chars]}\n... [truncated]"
    end
  end
end
