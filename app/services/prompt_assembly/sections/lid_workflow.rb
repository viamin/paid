# frozen_string_literal: true

# LID-aware workflow section. Wraps {Lid::InjectIntoPrompt} to produce the
# LID guidance when the project declares a lid_mode.
class PromptAssembly::Sections::LidWorkflow
  include PromptAssembly::Sections::Base

  private

  def build_section
    injected = Lid::InjectIntoPrompt.call(
      prompt: "",
      project: project,
      goal: agent_run&.goal
    )
    injected.strip
  end

  def inclusion_reason
    "LID-aware workflow guidance"
  end
end
