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
    def self.call(slug:, fallback:, project: nil, variables: {})
      # Prompt.resolve includes global scope as a fallback (project > account > global),
      # so passing a project for a global-only slug still finds the prompt.
      prompt = if project
        Prompt.resolve(slug, project: project)
      else
        Prompt.global.active.find_by(slug: slug)
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

    # Single-pass `{{var}}` interpolation. Unlike a sequence of `gsub` calls,
    # values that themselves contain `{{other_var}}` are *not* re-substituted on
    # later iterations — important when the values come from arbitrary content
    # like other prompt templates or agent log output.
    #
    # Variable names must match `\w+` (letters, digits, underscores only).
    # Accepts vars with either string or symbol keys. Unknown placeholders are
    # left in place so callers can spot drift.
    def self.interpolate(template, vars)
      return template.to_s if template.nil?
      return template.to_s if vars.empty?

      template.to_s.gsub(/\{\{(\w+)\}\}/) do
        key = Regexp.last_match(1)
        if vars.key?(key.to_sym)
          vars[key.to_sym].to_s
        elsif vars.key?(key)
          vars[key].to_s
        else
          Regexp.last_match(0)
        end
      end
    end
  end
end
