# frozen_string_literal: true

# Entry point for assembling create_pr `custom_prompt`-driven prompts through
# PromptAssembly. Pre-fetches shared data (issue comments, knowledge) for the
# project's settings, configures the ordered section providers, and delegates
# to {PromptAssembly::Build}.
#
# The custom task text is preserved verbatim as a `task.custom` section
# (required). Required safety and settings-derived sections
# (`service_environment`, `safety_rules`, and TDD boundaries when the run is
# TDD-governed) are always contributed and marked `required: true`, so profile
# suppression or template overrides cannot omit them. Optional sections
# (style guides, project conventions, LID workflow, marketplace attachments)
# are added when their backing project state is present, matching the
# create_pr issue path.
#
# @spec PROMPT-ASSEMBLY-019, PROMPT-ASSEMBLY-020, PROMPT-ASSEMBLY-021,
#       PROMPT-ASSEMBLY-022
#
# @example
#   result = PromptAssembly::BuildCustomPrompt.call(
#     custom_prompt: prompt_text, project: project, agent_run: run
#   )
#   result.text        # => "# Task\n\n..." with mandatory sections appended
#   result.provenance  # => { digest: "...", sections: [...], ... }
class PromptAssembly::BuildCustomPrompt
  def self.call(...)
    new(...).call
  end

  attr_reader :custom_prompt, :project, :agent_run

  def initialize(custom_prompt:, project:, agent_run: nil)
    @custom_prompt = custom_prompt.to_s
    @project = project
    @agent_run = agent_run
  end

  def call
    context = PromptAssembly::Context.new(
      project: project,
      agent_run: agent_run
    )

    PromptAssembly::Build.call(
      sections: sections_for(context),
      profile: resolved_profile
    )
  end

  private

  def resolved_profile
    PromptAssembly::ProfileResolution.resolve(
      project: project,
      account: project&.account,
      goal: agent_run&.goal || "create_pr"
    )
  end

  def sections_for(context)
    sections = [
      task_custom_section,
      PromptAssembly::Sections::ContinuationContext.call(context),
      required_service_environment(context),
      PromptAssembly::Sections::StyleGuides.call(context),
      PromptAssembly::Sections::ProjectConventions.call(context),
      PromptAssembly::Sections::LidWorkflow.call(context),
      PromptAssembly::Sections::MarketplaceAttachments.call(context),
      PromptAssembly::Sections::SafetyRules.call(context)
    ]
    sections << PromptAssembly::Sections::TddBoundaries.call(context) if agent_run&.tdd_governed?
    sections
  end

  def task_custom_section
    PromptAssembly::Section.new(
      key: :task_custom,
      source: :custom_prompt,
      content: custom_prompt,
      trust_level: :trusted,
      required: true,
      inclusion_reason: "user-provided custom task"
    )
  end

  # The settings-derived service environment is mandatory for any prompt that
  # instructs the agent to run code, so a profile cannot suppress it even when
  # the custom task text did not request it.
  def required_service_environment(context)
    section = PromptAssembly::Sections::ServiceEnvironment.call(context)
    return section if section.required? || section.blank?

    PromptAssembly::Section.new(
      key: section.key,
      content: section.content,
      trust_level: section.trust_level,
      required: true,
      inclusion_reason: "service container guardrails",
      source: section.source,
      metadata: section.metadata
    )
  end
end
