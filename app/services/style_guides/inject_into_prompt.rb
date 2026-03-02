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

      "#{prompt}\n#{style_guide_section(guides)}"
    end

    private

    def style_guide_section(guides)
      sections = guides.map { |guide| format_guide(guide) }

      <<~SECTION

        # Style Guide

        Follow these coding conventions for this project:

        #{sections.join("\n\n")}
      SECTION
    end

    def format_guide(guide)
      label = guide.project_level? ? "(project)" : guide.account_level? ? "(account)" : "(global)"
      content = guide.content_for_prompt

      "## #{guide.name} #{label}\n\n#{content}"
    end
  end
end
