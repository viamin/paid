# frozen_string_literal: true

# Database and infrastructure service environment guidance. Wraps
# {Prompts::ServiceContainerSections} so the agent knows which services are
# available and what database setup constraints apply.
class PromptAssembly::Sections::ServiceEnvironment
  include PromptAssembly::Sections::Base

  private

  def build_section
    Prompts::ServiceContainerSections.service_environment_section_for(
      project: project,
      include_setup_instruction: false
    )
  end

  def inclusion_reason
    "available services and database setup constraints"
  end
end
