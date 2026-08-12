# frozen_string_literal: true

module PromptAssembly
  # A prompt assembly profile: which optional sections a caller wants to
  # suppress. Safety-critical (required) sections are never suppressed.
  #
  # @spec PROMPT-ASSEMBLY-005
  class Profile
    attr_reader :disabled_sections

    def initialize(disabled_sections: [])
      @disabled_sections = Array(disabled_sections).map(&:to_sym).freeze
    end

    def section_enabled?(section)
      section.required? || !disabled_sections.include?(section.key)
    end
  end
end
