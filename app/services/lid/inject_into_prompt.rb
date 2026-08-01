# frozen_string_literal: true

module Lid
  class InjectIntoPrompt
    SECTION_HEADING = "## LID-Aware Workflow"
    PROMPT_SLUG = "coding.lid_aware_section"

    FALLBACK_PROMPT = <<~'PROMPT'
      ## LID-Aware Workflow

      This repository declares Linked-Intent Development mode: `{{lid_mode}}`.

      - Read `docs/high-level-design.md`, the relevant LLDs under `docs/intent/`, and the cited EARS specs for the area this issue or PR touches.
      - Walk the arrow before changing code: confirm the EARS trace to the LLD and the LLD traces to the HLD. If intent changed, update the spec and design docs first, then cascade into tests and code.
      - Work tests first. Add `@spec` annotations in tests citing the EARS IDs, then add matching `@spec` annotations at the implementation-graph entry points for the behavior you changed.
      - Run `{{coherence_check_command}}` for the structural checks before you finish. Treat failures as soft-blocks: fix forward, never skip hooks, and never use `--no-verify`.
      - Record LID phase progress in the PR description: which specs you touched, what tests-first evidence you added, and the coherence-check result.
      {{scope_instruction}}
    PROMPT

    def self.call(...)
      new(...).call
    end

    attr_reader :prompt, :project

    def initialize(prompt:, project:)
      @prompt = prompt.to_s
      @project = project
    end

    def call
      return prompt if prompt.include?(SECTION_HEADING)

      section = build_section
      return prompt if section.blank?

      "#{prompt.rstrip}\n\n#{section}\n"
    end

    private

    def build_section
      return if lid_mode.blank?

      vars = {
        lid_mode: lid_mode,
        coherence_check_command: coherence_check_command,
        scope_instruction: scope_instruction
      }

      Prompts::Render.call(
        slug: PROMPT_SLUG,
        project: project,
        variables: vars,
        fallback: -> { Prompts::Render.interpolate(FALLBACK_PROMPT, vars) }
      ).to_s.delete("\x00").strip
    end

    def lid_mode
      return unless project.respond_to?(:lid_mode)

      value = project.lid_mode.to_s.strip.downcase
      value.presence
    end

    def coherence_check_command
      "`bin/coherence-check.mjs` (preferred) or `/opt/paid-lid/bin/coherence-check.mjs` if the project does not vendor it"
    end

    def scope_instruction
      return "" unless lid_mode == "scoped"

      "- Because this repository is in Scoped mode, check the instruction file's `## LID Scope` include/exclude rules and only walk the arrow for in-scope paths."
    end
  end
end
