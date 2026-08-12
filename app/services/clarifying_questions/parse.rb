# frozen_string_literal: true

module ClarifyingQuestions
  class Parse
    ENHANCEMENT_MARKER = "<!-- paid:enhance-issue -->"
    CLARIFYING_SECTION_PATTERN = /^##\s+.*clarifying questions[^\n]*\n(.+?)(?=^## |\z)/mi.freeze

    def self.call(...)
      new(...).call
    end

    def initialize(comment_body:)
      @comment_body = comment_body.to_s
    end

    def call
      return [] unless comment_body.include?(ENHANCEMENT_MARKER)
      return [] unless comment_body.match?(CLARIFYING_SECTION_PATTERN)

      section = extract_clarifying_section
      return [] unless section

      parse_numbered_items(section)
    end

    private

    attr_reader :comment_body

    def extract_clarifying_section
      match = comment_body.match(CLARIFYING_SECTION_PATTERN)
      match ? match[1] : nil
    end

    def parse_numbered_items(text)
      questions = []
      current = nil

      text.each_line do |line|
        stripped = line.strip
        if (match = stripped.match(/\A\d+\.\s+(.+)\z/))
          questions << current if current
          current = match[1]
        elsif current.present? && stripped.present?
          current += " " + stripped
        end
      end
      questions << current if current

      questions
    end
  end
end
