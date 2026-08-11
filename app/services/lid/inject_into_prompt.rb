# frozen_string_literal: true

module Lid
  class InjectIntoPrompt
    # @spec LID-RUNS-001
    SECTION_HEADING = "## LID-Aware Workflow"
    PROMPT_SLUG = "coding.lid_aware_section"

    FALLBACK_PROMPT = <<~'PROMPT'
      ## LID-Aware Workflow

      This repository declares Linked-Intent Development mode: `{{lid_mode}}`.

      - Read the project's high-level design doc and the relevant LLDs/EARS specs for the area this issue or PR touches. The conventional LID paths are `docs/high-level-design.md` and `docs/intent/`, but they may vary by project — locate the actual design docs if the standard paths are absent.
      - Walk the arrow before changing code: confirm the EARS trace to the LLD and the LLD traces to the HLD. If intent changed, update the spec and design docs first, then cascade into tests and code.
      - When the run includes confirmed elicited intent from issue enhancement, materialize that intent into draft or updated LLD and EARS artifacts before or alongside code changes.
      - Work tests first. Add `@spec` annotations in tests citing the EARS IDs, then add matching `@spec` annotations at the implementation-graph entry points for the behavior you changed.
      - Run `{{coherence_check_command}}` for the structural checks before you finish. Treat failures as soft-blocks: fix forward, never skip hooks, and never use `--no-verify`.
      - Record LID phase progress in the PR description: which specs you touched, what tests-first evidence you added, and the coherence-check result.
      {{scope_instruction}}
    PROMPT

    # Lightweight prompts for goals that don't implement code.
    # These skip spec walks, coherence checks, and @spec annotations.

    ENHANCE_ISSUE_FALLBACK = <<~'PROMPT'
      ## LID-Aware Workflow

      This repository declares Linked-Intent Development mode: `{{lid_mode}}`.

      - Read the issue description and all comments carefully to understand the change request.
      - If design docs exist (`docs/high-level-design.md`, LLDs under `docs/intent/`), reference them for context on the affected area.
      - Elicit missing intent: ask specific clarifying questions, suggest relevant files and architectural considerations.
      - Your goal is to enhance the issue with enough implementation context for a coding agent to proceed — not to implement code or walk spec traces.
      {{scope_instruction}}
    PROMPT

    ANALYZE_ISSUE_FALLBACK = <<~'PROMPT'
      ## LID-Aware Workflow

      This repository declares Linked-Intent Development mode: `{{lid_mode}}`.

      - Read the issue description and comments to understand the change request.
      - If design docs exist (`docs/high-level-design.md`, LLDs under `docs/intent/`), reference them for scope and complexity assessment.
      - Determine whether the issue has sufficient context to begin implementation.
      - Your goal is to assess scope and complexity — not to implement code or walk spec traces.
      {{scope_instruction}}
    PROMPT

    REVIEW_FALLBACK = <<~'PROMPT'
      ## LID-Aware Workflow

      This repository declares Linked-Intent Development mode: `{{lid_mode}}`.

      - Reference design docs (`docs/high-level-design.md`, LLDs under `docs/intent/`) for context on the affected area.
      - Review the code against the design intent captured in those docs.
      - Do NOT walk spec traces, add `@spec` annotations, or invoke `bin/coherence-check.mjs` yourself — the system runs the coherence check on your behalf. This is a review, not an implementation run.
      {{scope_instruction}}
    PROMPT

    CREATE_ISSUE_FALLBACK = <<~'PROMPT'
      ## LID-Aware Workflow

      This repository declares Linked-Intent Development mode: `{{lid_mode}}`.

      - Read the issue description and comments to understand what issue to draft.
      - If design docs exist (`docs/high-level-design.md`, LLDs under `docs/intent/`), reference them for context on the affected area.
      - Draft a clear, well-scoped issue with sufficient implementation context for a coding agent to proceed.
      - Your goal is to create a well-formed issue — not to implement code or walk spec traces.
      {{scope_instruction}}
    PROMPT

    # Goals that receive the full implementation contract.
    FULL_CONTRACT_GOALS = %w[create_pr create_feature lid_planning].freeze

    def self.call(prompt:, project:, goal: nil)
      new(prompt: prompt, project: project, goal: goal).call
    end

    def self.section_for(project:, goal: nil)
      new(prompt: "", project: project, goal: goal).section
    end

    attr_reader :prompt, :project, :goal

    def initialize(prompt:, project:, goal: nil)
      @prompt = prompt.to_s
      @project = project
      @goal = goal.to_s.presence
    end

    def call
      return prompt if prompt.include?(SECTION_HEADING)

      section = section()
      return prompt if section.blank?

      "#{prompt.rstrip}\n\n#{section}\n"
    end

    def section
      build_section
    end

    private

    def build_section
      return if lid_mode.blank?

      vars = {
        lid_mode: lid_mode,
        coherence_check_command: coherence_check_command,
        scope_instruction: scope_instruction
      }

      trimmed = full_contract_goal? ? nil : fallback_for_goal(goal)

      if trimmed
        Prompts::Render.interpolate(trimmed, vars).strip
      else
        Prompts::Render.call(
          slug: PROMPT_SLUG,
          project: project,
          variables: vars,
          fallback: -> { Prompts::Render.interpolate(FALLBACK_PROMPT, vars) }
        ).to_s.delete("\x00").strip
      end
    end

    def full_contract_goal?
      FULL_CONTRACT_GOALS.include?(goal)
    end

    def fallback_for_goal(goal)
      case goal
      when "enhance_issue" then ENHANCE_ISSUE_FALLBACK
      when "analyze_issue" then ANALYZE_ISSUE_FALLBACK
      when "review" then REVIEW_FALLBACK
      when "create_issue" then CREATE_ISSUE_FALLBACK
      end
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
