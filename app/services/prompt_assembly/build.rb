# frozen_string_literal: true

require "digest"

module PromptAssembly
  # Assembles a prompt from ordered sections, enforcing the trust and safety
  # contract. The assembler fails closed: any section it cannot trust, or any
  # ordinary profile that tries to weaken a safety section, raises a
  # non-retryable PromptAssembly::Error instead of producing a prompt.
  class Build
    def self.call(context:, sections:, profile: nil)
      new(context: context, sections: sections, profile: profile).call
    end

    def initialize(context:, sections:, profile: nil)
      @context = context
      @sections = sections
      @profile = profile
    end

    # @spec PROMPT-ASSEMBLY-001
    # @spec PROMPT-ASSEMBLY-002
    # @spec PROMPT-ASSEMBLY-003
    # @spec PROMPT-ASSEMBLY-004
    # @spec PROMPT-ASSEMBLY-005
    def call
      included, skipped = select_sections

      validate_metadata!(included)
      prompt = render_prompt(included)

      Result.new(
        prompt: prompt,
        sections: included,
        skipped_sections: skipped,
        provenance: build_provenance(prompt, included, skipped)
      )
    end

    private

    def select_sections
      included = []
      skipped = []

      order_sections.each do |section|
        if section.empty?
          skipped << SkippedSection.new(key: section.key, reason: "empty")
        elsif profile_disabled?(section)
          skipped << SkippedSection.new(key: section.key, reason: "disabled_by_profile")
        else
          included << section
        end
      end

      [ included, skipped ]
    end

    def profile_disabled?(section)
      return false unless @profile&.disabled?(section.key)

      if section.safety? && !@profile.safety_overrides_allowed?
        raise SafetySectionDisabled,
          "profile #{@profile.name.inspect} cannot disable safety section #{section.key.inspect}"
      end

      true
    end

    def order_sections
      return @sections if @profile.nil? || @profile.order.empty?

      index = @profile.order.each_with_index.to_h
      @sections.sort_by { |section| index.fetch(section.key, @profile.order.size) }
    end

    def validate_metadata!(sections)
      sections.each { |section| validate_section!(section) }
    end

    def validate_section!(section)
      raise MissingSectionKey if section.key.blank?
      if section.trust_level.blank?
        raise MissingTrustMetadata, "section #{section.key.inspect} is missing its trust level"
      end
      raise MissingTrustMetadata, "section #{section.key.inspect} is missing its source" if section.source.blank?
      if section.inclusion_reason.blank?
        raise MissingInclusionReason, "section #{section.key.inspect} is missing its inclusion reason"
      end
      if Trust::TRUST_LEVELS.exclude?(section.trust_level)
        raise UnknownTrustLevel,
          "section #{section.key.inspect} has unknown trust level #{section.trust_level.inspect}"
      end
      return unless incompatible_render_mode?(section)

      raise IncompatibleRenderMode,
        "section #{section.key.inspect} render mode #{section.render_mode.inspect} is incompatible " \
        "with trust level #{section.trust_level.inspect}"
    end

    def incompatible_render_mode?(section)
      section.render_mode && section.render_mode != section.permitted_render_mode
    end

    def render_prompt(sections)
      sections.map(&:render).join("\n\n")
    end

    def build_provenance(prompt, included, skipped)
      {
        goal: @context.goal,
        profile: @profile&.name,
        safety_overrides_allowed: @profile&.safety_overrides_allowed?,
        ordered_keys: included.map(&:key),
        sections: included.map { |section| section_provenance(section) },
        skipped: skipped.map(&:to_h),
        safety_included: included.select(&:safety?).map(&:key),
        digest: digest(prompt)
      }
    end

    def section_provenance(section)
      {
        key: section.key,
        source: section.source,
        trust_level: section.trust_level,
        render_mode: section.resolved_render_mode,
        required: section.required?,
        safety: section.safety?,
        inclusion_reason: section.inclusion_reason,
        token_estimate: section.token_estimate,
        provenance: section.provenance
      }
    end

    def digest(text)
      Digest::SHA256.hexdigest(text)
    end
  end
end
