# frozen_string_literal: true

module PromptAssembly
  # Assembles ordered sections into a prompt plus provenance.
  #
  # @spec PROMPT-ASSEMBLY-005, PROMPT-ASSEMBLY-006, PROMPT-ASSEMBLY-012,
  #       PROMPT-ASSEMBLY-013
  #
  # Fails closed: a section with invalid trust metadata raises before any
  # prompt text is produced. Excluded sections are dropped from the text and
  # recorded as counts/provenance only; disabled optional sections are skipped
  # unless they are safety-critical (required). The profile's section ordering
  # is applied to optional sections, and the profile fingerprint is recorded
  # in the result.
  class Build
    attr_reader :profile

    def initialize(profile: Profile.new)
      @profile = profile
    end

    def self.call(sections:, profile: Profile.new)
      new(profile: profile).call(sections)
    end

    def call(sections)
      coerced = Array(sections).map { |section| coerce_section(section) }

      included = []
      skipped = []
      budget_decisions = []

      ordered_sections(coerced).each do |section|
        if section.excluded?
          skipped << skip_provenance(section, reason: section.exclusion_reason || "excluded")
        elsif profile.section_enabled?(section)
          decision = apply_budget(section)
          budget_decisions << decision if decision
          included << section
        else
          skipped << skip_provenance(section, reason: "disabled_by_profile")
        end
      end

      rendered_sections = included.reject(&:blank?)
      text = rendered_sections.map(&:render).join("\n\n")

      Result.new(
        text: text,
        sections: rendered_sections,
        skipped: skipped,
        profile_fingerprint: profile.fingerprint,
        budget_decisions: budget_decisions
      )
    end

    private

    def ordered_sections(sections)
      profile.ordered_sections(sections)
    end

    def apply_budget(section)
      budget = profile.budget_for(section.key)
      return unless budget && budget.is_a?(Hash)

      {
        section: section.key.to_s,
        budget: budget.transform_keys(&:to_s)
      }
    end

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
        login: section.login,
        trust_level: section.trust_level,
        reason: reason
      }.compact
    end
  end
end
