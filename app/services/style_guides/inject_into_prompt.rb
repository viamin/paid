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
    # Total byte budget for all injected style guide sections combined.
    # Guides are prioritized by specificity (project > account > global);
    # once the budget is exhausted, remaining guides are omitted.
    MAX_TOTAL_BYTES = 32_000

    attr_reader :prompt, :project

    def initialize(prompt:, project:)
      @prompt = prompt
      @project = project
    end

    def self.call(...)
      new(...).call
    end

    def call
      guides = StyleGuide.resolve_for(project)
      return prompt if guides.empty?

      sections = collect_sections_within_budget(guides)
      return prompt if sections.empty?

      "#{prompt}\n#{style_guide_section(sections)}"
    end

    private

    def collect_sections_within_budget(guides)
      total_bytes = 0
      guides.filter_map do |guide|
        section = format_guide(guide)
        next if section.nil?
        next if total_bytes + section.bytesize > MAX_TOTAL_BYTES

        total_bytes += section.bytesize
        section
      end
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
