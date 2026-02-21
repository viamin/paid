# frozen_string_literal: true

module Prompts
  # Resolves the effective prompt version for a given slug and project context,
  # using inheritance: project > account > global.
  #
  # @example
  #   version = Prompts::Resolve.call(slug: "coding.issue_implementation", project: project)
  #   rendered = version.render(title: issue.title, body: issue.body)
  class Resolve
    attr_reader :slug, :project

    def initialize(slug:, project:)
      @slug = slug
      @project = project
    end

    def self.call(...)
      new(...).resolve
    end

    # @return [PromptVersion, nil] The current version of the most specific matching prompt
    def resolve
      prompt = Prompt.resolve(slug, project: project)
      prompt&.current_version
    end
  end
end
