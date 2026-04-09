# frozen_string_literal: true

module Prompts
  # Resolves a prompt slug, renders it with variables, and falls back to an
  # in-code default if no active prompt is found. Always returns a String.
  #
  # During rollout we prefer falling back + warning over raising, so a
  # mis-seeded or deactivated prompt cannot break agent execution. Once the
  # database-backed prompts are stable, callers can switch to raising on miss.
  #
  # @example
  #   Prompts::Render.call(
  #     slug: "diagnostics.agent_run_failure",
  #     project: project,
  #     variables: { error_text: "...", logs_text: "..." },
  #     fallback: -> { legacy_inline_prompt }
  #   )
  class Render
    def self.call(slug:, variables: {}, project: nil, fallback:)
      prompt = if project
        Prompt.resolve(slug, project: project)
      else
        Prompt.active.global.find_by(slug: slug)
      end

      version = prompt&.current_version
      if version.nil?
        Rails.logger.warn(
          message: "prompts.render_fallback",
          slug: slug,
          project_id: project&.id,
          reason: "no_active_version"
        )
        return fallback.call
      end

      version.render(variables)
    end
  end
end
