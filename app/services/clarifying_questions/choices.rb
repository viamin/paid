# frozen_string_literal: true

module ClarifyingQuestions
  # Strict reader-side parser for choice questions in the enhancement
  # comment's clarifying-question list.
  #
  # The `goal.enhance_issue` prompt lets the authoring agent opt a question
  # into choice semantics by emitting sub-list marker lines under the
  # numbered question:
  #
  #   1. Which storage backend should the export use?
  #      - ( ) SQLite) local file, zero setup
  #      - ( ) Postgres) already used for app data
  #
  # `ClarifyingQuestions::Parse#parse_numbered_items` folds those sub-lines
  # into the question string (joined with spaces), so the markers survive
  # inline and this service only ever sees the folded question. Matching is
  # strict: the exact marker spellings only — no prose heuristics and no
  # legacy `a)/b)` detection. Anything malformed, partial (fewer than two
  # options), or marker-less returns nil so the question renders as free
  # text.
  #
  # The question string itself is never modified — choices are a view-time
  # attribute only; the strings `Parse` produces must stay byte-identical
  # for the inbox tamper guard and answer reconciliation.
  # @spec ISSUE-ENHANCEMENT-018
  class Choices
    SINGLE_MARKER_TEXT = "- ( ) ".freeze
    # `- [x]` is accepted alongside `- [ ]` (the prompt's unchecked-box
    # spelling) so a checked-box emission still parses as multi-choice.
    MULTI_MARKER_TEXTS = [ "- [ ] ", "- [x] " ].freeze
    ANY_MARKER = Regexp.union(SINGLE_MARKER_TEXT, *MULTI_MARKER_TEXTS).freeze
    # `- ( ) Label) description` — the label ends at the first `)` and must
    # be non-empty; the description runs to the next marker (or the end of
    # the folded question) and must be non-empty.
    OPTION_PATTERN = /\A([^)]+?)\)\s*(.+)\z/.freeze
    MIN_OPTIONS = 2

    def self.call(...)
      new(...).call
    end

    def initialize(question:)
      @question = question.to_s
    end

    def call
      types = marker_types.uniq
      options = option_contents.map { |content| build_option(content) }
      return nil if types.size != 1
      return nil if options.include?(nil) || options.size < MIN_OPTIONS

      { type: types.first, options: options }
    end

    private

    attr_reader :question

    def marker_types
      question.scan(ANY_MARKER).map { |marker| marker == SINGLE_MARKER_TEXT ? :single : :multi }
    end

    # Everything after the first marker, split between markers: the prose
    # before the first marker is the question itself and is ignored.
    def option_contents
      question.split(ANY_MARKER, -1).drop(1).map(&:strip)
    end

    def build_option(content)
      match = content.match(OPTION_PATTERN)
      return nil unless match

      { label: match[1].strip, text: match[2].strip }
    end
  end
end
