# frozen_string_literal: true

module Issues
  # Cheap structural heuristic for whether an issue body looks truncated or
  # corrupted — cut off mid-sentence, mid-word, or inside an unterminated
  # code fence or heading — rather than a deliberate NLP judgment. Detection
  # is a structural fact (ZFC: code's job); whether that fact matters for a
  # given verdict is left to the analyzer/enhancer prompts.
  #
  # @spec ISSUE-ANALYSIS-016
  #
  # @example
  #   Issues::DetectTruncatedBody.call(issue.body) # => true/false
  class DetectTruncatedBody
    # Bodies shorter than this are too short for "ends without terminal
    # punctuation" to be a meaningful signal (e.g. "Fix typo in README").
    MIN_LENGTH = 60
    TERMINAL_CHARACTERS = [ ".", "!", "?", ":", ";", ")", "]", "}", "\"", "'", "`", "*", "_", ">", "|", "-", "…" ].freeze
    LIST_ITEM_PATTERN = /\A\s*([-*+]|\d+[.)])(\s|\z)/
    HEADING_PATTERN = /\A\s*\#{1,6}(\s|\z)/
    FENCE_LINE_PATTERN = /^\s*```/
    # A line that ends in a bare link (logs, repros, gists) is a well-formed
    # ending even though the URL's last character is not terminal punctuation.
    BARE_LINK_ENDING_PATTERN = /(?:[a-z][a-z0-9+.-]*:\/\/|www\.)\S+\z/i

    def self.call(body)
      new(body).call
    end

    def initialize(body)
      @body = body.to_s
    end

    def call
      return false if trimmed.length < MIN_LENGTH
      return true if unterminated_code_fence?
      return true if dangling_heading?

      !well_formed_ending?
    end

    private

    attr_reader :body

    def trimmed
      @trimmed ||= body.strip
    end

    def last_line
      @last_line ||= trimmed.lines.last.to_s.strip
    end

    # An odd number of fence lines means the body ends while still "inside"
    # a code block — the closing fence was never written.
    def unterminated_code_fence?
      trimmed.scan(FENCE_LINE_PATTERN).size.odd?
    end

    # The body's last line is a heading with nothing written underneath it —
    # a section was started and the body ends before any content follows.
    def dangling_heading?
      HEADING_PATTERN.match?(last_line)
    end

    def well_formed_ending?
      LIST_ITEM_PATTERN.match?(last_line) ||
        last_line.start_with?("```") ||
        last_line.match?(BARE_LINK_ENDING_PATTERN) ||
        TERMINAL_CHARACTERS.include?(last_line[-1])
    end
  end
end
