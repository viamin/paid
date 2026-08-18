# frozen_string_literal: true

# Repository automation conventions (commit style, PR title format,
# dependency phrasing). Wraps {ProjectConventions::InjectIntoPrompt}.
class PromptAssembly::Sections::ProjectConventions
  include PromptAssembly::Sections::Base

  private

  def build_section
    injected = ProjectConventions::InjectIntoPrompt.call(
      prompt: "",
      project: project
    )
    injected.strip
  end

  def inclusion_reason
    "repository automation conventions"
  end
end
