# frozen_string_literal: true

# Coding style guides resolved for the project. Wraps
# {StyleGuides::InjectIntoPrompt} to produce the style guide section.
class PromptAssembly::Sections::StyleGuides
  include PromptAssembly::Sections::Base

  private

  def build_section
    injected = StyleGuides::InjectIntoPrompt.call(
      prompt: "",
      project: project,
      agent_run: agent_run,
      source: self.class.name
    )
    injected.strip
  end

  def inclusion_reason
    "project coding style guides"
  end
end
