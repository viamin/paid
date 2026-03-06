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

      sections = guides.filter_map { |guide| format_guide(guide) }
      return prompt if sections.empty?

      "#{prompt}\n#{style_guide_section(sections)}"
    end

    private

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
