# frozen_string_literal: true

module ClarifyingQuestions
  # Extracts the "Current Context" section and the preamble (the prose
  # between the clarifying-questions heading and the first numbered item)
  # from a Paid enhancement comment so the inbox can surface the context
  # the operator needs to answer the questions.
  #
  # Returns nil when neither section is present (e.g. when the questions
  # came from locally persisted `needs_input_questions` rather than a
  # fetched comment), so callers can use a single null-check to decide
  # whether to render the panel.
  class Context
    CURRENT_CONTEXT_HEADING = /\A##\s+Current context\s*\z/i.freeze
    HEADING_BOUNDARY = /\A##\s+/.freeze
    PREAMBLE_BOUNDARY = /\A\d+\.\s+/.freeze

    def self.call(...)
      new(...).call
    end

    def initialize(comment_body:)
      @comment_body = comment_body.to_s
    end

    def call
      body = comment_body.sub(Parse::ENHANCEMENT_MARKER, "").strip
      return nil if body.blank?

      preamble = extract_preamble(body)
      current_context = extract_current_context(body)

      sections = []
      sections << preamble if preamble.present?
      sections << current_context if current_context.present?

      return nil if sections.empty?

      sections.join("\n\n")
    end

    private

    attr_reader :comment_body

    # Walk the body by lines, collecting lines that belong to either
    # the "Current Context" section (until the next ## heading) or the
    # clarifying-questions preamble (between the heading and the first
    # numbered item). Both surfaces belong to the same comment but the
    # parser above only kept the numbered items, so we recover them here.
    def extract_preamble(body)
      lines = body.lines.map(&:chomp)
      questions_index = lines.index { |line| line.match?(Parse::CLARIFYING_SECTION_HEADING) }
      return nil if questions_index.nil?

      preamble_lines = []
      lines[(questions_index + 1)..].each do |line|
        break if line.match?(PREAMBLE_BOUNDARY)
        break if line.match?(HEADING_BOUNDARY)

        preamble_lines << line
      end

      text = preamble_lines.join("\n").strip
      text.presence
    end

    def extract_current_context(body)
      lines = body.lines.map(&:chomp)
      heading_index = lines.index { |line| line.match?(CURRENT_CONTEXT_HEADING) }
      return nil if heading_index.nil?

      context_lines = []
      lines[(heading_index + 1)..].each do |line|
        break if line.match?(HEADING_BOUNDARY)

        context_lines << line
      end

      text = context_lines.join("\n").strip
      text.presence
    end
  end
end
