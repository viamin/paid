# frozen_string_literal: true

module PromptAssembly
  # Assembles ordered sections into a prompt plus provenance.
  #
  # @spec PROMPT-ASSEMBLY-005, PROMPT-ASSEMBLY-006
  #
  # Fails closed: a section with invalid trust metadata raises before any
  # prompt text is produced. Excluded sections are dropped from the text and
  # recorded as counts/provenance only; disabled optional sections are skipped
  # unless they are safety-critical (required).
  class Build
    attr_reader :profile

    def initialize(profile: Profile.new)
      @profile = profile
    end

    def self.call(sections:, profile: Profile.new)
      new(profile: profile).call(sections)
    end

    def call(sections)
      included = []
      skipped = []

      Array(sections).each do |section|
        section = coerce_section(section)
        if section.excluded?
          skipped << skip_provenance(section, reason: section.exclusion_reason || "excluded")
        elsif profile.section_enabled?(section)
          included << section
        else
          skipped << skip_provenance(section, reason: "disabled_by_profile")
        end
      end

      Result.new(
        text: included.reject(&:blank?).map(&:render).join("\n\n"),
        sections: included,
        skipped: skipped
      )
    end

    private

    # Accepts Section objects or anything that converts to one (TrustedInput).
    def coerce_section(section)
      return section if section.is_a?(Section)
      return section.to_section if section.respond_to?(:to_section)

      raise ArgumentError, "expected PromptAssembly::Section, got #{section.class}"
    end

    def skip_provenance(section, reason:)
      {
        key: section.key,
        source: section.source,
        trust_level: section.trust_level,
        reason: reason
      }.compact
    end
  end
end
