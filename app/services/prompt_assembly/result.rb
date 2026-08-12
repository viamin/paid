# frozen_string_literal: true

module PromptAssembly
  # The assembled output: prompt text plus the provenance explaining what
  # reached the agent and why. Callers execute +prompt+ and persist
  # +provenance+ for audit and preview.
  class Result
    attr_reader :prompt, :sections, :skipped_sections, :warnings, :provenance

    def initialize(prompt:, sections:, skipped_sections: [], warnings: [], provenance: {})
      @prompt = prompt
      @sections = sections
      @skipped_sections = skipped_sections
      @warnings = warnings
      @provenance = provenance
    end
  end
end
