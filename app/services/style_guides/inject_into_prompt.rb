# frozen_string_literal: true

module StyleGuides
  # Injects compressed style guide content into an agent prompt.
  # Resolves applicable style guides for the project and appends them.
  #
  # @example
  #   full_prompt = StyleGuides::InjectIntoPrompt.call(
  #     prompt: base_prompt,
  #     project: project
  #   )
  class InjectIntoPrompt
    # Total byte budget (in bytes) for all injected style guide section contents
    # combined. This limit applies only to the per-guide sections returned by
    # `format_guide` and does not include the static wrapper/header or join
    # separators added by `style_guide_section`. Guides are prioritized by
    # specificity (project > account > global); once the budget is exhausted,
    # remaining guides are omitted.
    # Default total byte budget for injected style guide sections.
    # Overridden by UserSetting#style_guide_max_total_bytes at runtime.
    DEFAULT_MAX_TOTAL_BYTES = 32_000

    attr_reader :prompt, :project

    def initialize(prompt:, project:)
      @prompt = prompt
      @project = project
    end

    def self.call(...)
      new(...).call
    end

    def call
      guides = StyleGuide.resolve_for(project).to_a
      return prompt if guides.empty?

      sections = collect_sections_within_budget(guides)
      return prompt if sections.empty?

      combined_prompt = "#{prompt}\n#{style_guide_section(sections)}"
      combined_prompt.delete("\x00")
    end

    private

    def collect_sections_within_budget(guides)
      budget = max_total_bytes
      total_bytes = 0
      guides.filter_map do |guide|
        section = format_guide(guide)
        next if section.nil?
        next if total_bytes + section.bytesize > budget

        total_bytes += section.bytesize
        section
      end
    end

    def max_total_bytes
      settings = AgentRuns::UserSettingsResolver.call(project: project, strict: false)
      settings&.style_guide_max_total_bytes || DEFAULT_MAX_TOTAL_BYTES
    end

    def style_guide_section(sections)
      <<~SECTION

        # Style Guide

        Follow these coding conventions for this project:

        #{sections.join("\n\n")}
      SECTION
    end

    def format_guide(guide)
      label =
        if guide.project_level?
          "(project)"
        elsif guide.account_level?
          "(account)"
        else
          "(global)"
        end
      content = guide.content_for_prompt
      return if content.blank?

      "## #{guide.name} #{label}\n\n#{content}"
    end
  end
end
