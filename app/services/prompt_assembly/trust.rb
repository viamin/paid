# frozen_string_literal: true

module PromptAssembly
  # The trust model for prompt sections. Every section carries a trust level
  # that classifies the provenance of its content and determines the only
  # render mode under which the content may be assembled into a prompt.
  #
  # Trust levels:
  # - +trusted_instruction+: platform-authored safety/policy instructions.
  # - +trusted_user_instruction+: tenant-authored prompts, style guides, and
  #   other authenticated-user instructions.
  # - +trusted_collaborator_context+: allowlisted GitHub collaborator content
  #   (issue/PR bodies, comments, review threads) safe to treat as task text.
  # - +quarantined_context+: repository and external content that may contain
  #   hostile or stale instructions; rendered as quoted evidence only.
  module Trust
    TRUSTED_INSTRUCTION = "trusted_instruction"
    TRUSTED_USER_INSTRUCTION = "trusted_user_instruction"
    TRUSTED_COLLABORATOR_CONTEXT = "trusted_collaborator_context"
    QUARANTINED_CONTEXT = "quarantined_context"

    TRUST_LEVELS = [
      TRUSTED_INSTRUCTION,
      TRUSTED_USER_INSTRUCTION,
      TRUSTED_COLLABORATOR_CONTEXT,
      QUARANTINED_CONTEXT
    ].freeze

    RENDER_MODE_INSTRUCTION = :instruction
    RENDER_MODE_CONTEXT = :context

    RENDER_MODES = [ RENDER_MODE_INSTRUCTION, RENDER_MODE_CONTEXT ].freeze

    # The only render mode each trust level permits. Quarantined context may
    # render as quoted evidence, never as instructions.
    RENDER_MODES_BY_TRUST_LEVEL = {
      TRUSTED_INSTRUCTION => RENDER_MODE_INSTRUCTION,
      TRUSTED_USER_INSTRUCTION => RENDER_MODE_INSTRUCTION,
      TRUSTED_COLLABORATOR_CONTEXT => RENDER_MODE_INSTRUCTION,
      QUARANTINED_CONTEXT => RENDER_MODE_CONTEXT
    }.freeze
  end
end
