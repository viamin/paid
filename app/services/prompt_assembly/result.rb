# frozen_string_literal: true

module PromptAssembly
  # The output of a prompt assembly: prompt text plus provenance.
  #
  # +skipped+ records excluded or disabled sections as counts/provenance only —
  # never bodies — so untrusted content cannot leak through the result.
  class Result
    attr_reader :text, :sections, :skipped

    def initialize(text:, sections:, skipped: [])
      @text = text.to_s
      @sections = sections.freeze
      @skipped = skipped.freeze
      freeze
    end
  end
end
